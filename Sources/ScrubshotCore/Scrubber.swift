import CoreGraphics
import Foundation

public struct ScrubOptions {
    public var rules: RuleSet
    /// OCR scale for finding text. 2 reads small 1x text more reliably.
    public var ocrScale: Double
    /// OCR scales for the leak check on the output. More scales, stricter check.
    public var verifyScales: [Double]

    public init(rules: RuleSet, ocrScale: Double = 1, verifyScales: [Double] = [1, 2]) {
        self.rules = rules; self.ocrScale = ocrScale; self.verifyScales = verifyScales
    }
}

/// One replacement, as written to the --report JSON.
public struct ReplacementRecord: Codable {
    public var original: String
    public var replacement: String
    public var rule: String
    /// The whole OCR'd text that was redrawn (may include unchanged neighbors in the same word).
    public var redrawnFrom: String
    public var redrawnTo: String
    public var line: String
    public var render: EditResult?
    public var skipped: String?
}

public struct Leak: Codable, Equatable {
    public var text: String
    public var line: String
    public var rule: String
    public var box: PixelRect
    public var ocrScale: Double
}

public struct ScrubResult {
    public var image: CGImage
    public var replacements: [ReplacementRecord]
    public var leaks: [Leak]
    public var warnings: [String]
}

/// A span of OCR text that a rule matched, mapped to an observation.
struct PlannedEdit {
    var piece: OCRPiece
    /// Token-aligned range in `piece.text` that gets redrawn.
    var range: NSRange
    var keepPrefix: Int
    var newText: String
    var matches: [RuleMatch]
    var line: String
}

public enum Scrubber {
    public static func scrub(_ image: CGImage, options: ScrubOptions) throws -> ScrubResult {
        let bmp = try Bitmap(image: image)
        let pieces = try OCR.recognize(image, scale: options.ocrScale)
        let lines = OCR.lines(pieces)
        let plan = planEdits(lines: lines, rules: options.rules)

        // Measure every edit on the untouched image, agree on fonts, then draw.
        let requests = plan.map { e in
            EditRequest(box: e.piece.box(for: e.range), originalText: (e.piece.text as NSString).substring(with: e.range),
                        keepPrefix: e.keepPrefix, newText: e.newText)
        }
        let analyses = requests.map { Renderer.analyze($0, in: bmp) }
        let choices = consensus(analyses)
        if ProcessInfo.processInfo.environment["SCRUBSHOT_DEBUG"] != nil {
            for (i, a) in analyses.enumerated() {
                guard let a else { continue }
                let fits = a.fits.prefix(4).map { String(format: "%@ %.2f e=%.3f", $0.fontName, Double($0.size), $0.error) }
                FileHandle.standardError.write("[debug] \(a.request.originalText) ink=\(a.ink) choice=\(String(describing: choices[i])) fits: \(fits.joined(separator: " | "))\n".data(using: .utf8)!)
            }
        }

        var records: [ReplacementRecord] = []
        var warnings: [String] = []
        var redrawn: [PixelRect] = []
        for (i, e) in plan.enumerated() {
            let from = requests[i].originalText
            var result: EditResult?
            if let a = analyses[i], let c = choices[i], let f = Renderer.place(a, fontName: c.0, size: c.1) {
                result = Renderer.draw(a, fit: f, into: bmp)
            }
            let to = (from as NSString).substring(to: e.keepPrefix) + e.newText
            for m in e.matches {
                records.append(ReplacementRecord(
                    original: m.original, replacement: m.replacement, rule: m.rule,
                    redrawnFrom: from, redrawnTo: to, line: e.line, render: result,
                    skipped: result == nil ? "no text pixels found in the OCR box" : nil))
            }
            if let r = result {
                redrawn.append(r.fill)
                warnings += r.warnings.map { "\"\(from)\": \($0)" }
            } else {
                warnings.append("\"\(from)\": skipped, no text pixels found in the OCR box")
            }
        }
        let out = try bmp.makeImage()
        let leaks = try verify(out, rules: options.rules, originals: records.map(\.original),
                               redrawn: redrawn, scales: options.verifyScales)
        return ScrubResult(image: out, replacements: records, leaks: leaks, warnings: warnings)
    }

    /// Picks one font per group of similar-size edits, so short words (where one
    /// sample cannot tell fonts apart) follow the rest of the screenshot. An edit keeps
    /// its own best font when the group's font clearly fits it worse.
    static func consensus(_ analyses: [Renderer.Analysis?]) -> [(String, CGFloat)?] {
        var out = [(String, CGFloat)?](repeating: nil, count: analyses.count)
        let idx = analyses.indices.filter { analyses[$0] != nil }
            .sorted { (analyses[$0]!.fits[0].size, $0) < (analyses[$1]!.fits[0].size, $1) }
        var clusters: [[Int]] = []
        for i in idx {
            let s = analyses[i]!.fits[0].size
            if let first = clusters.last?.first, s <= analyses[first]!.fits[0].size * 1.08 {
                clusters[clusters.count - 1].append(i)
            } else {
                clusters.append([i])
            }
        }
        for cluster in clusters {
            let names = FontCandidate.all.map(\.name)
            var bestName = names[0], bestTotal = Double.infinity
            for n in names {
                let total = cluster.reduce(0.0) { $0 + (analyses[$1]!.fit(named: n)?.error ?? 1) }
                if total < bestTotal - 1e-12 { bestTotal = total; bestName = n }
            }
            var shared: [Int] = []
            for i in cluster {
                let a = analyses[i]!
                let own = a.fits[0]
                if let f = a.fit(named: bestName), f.error <= own.error * 1.5 + 0.02 {
                    out[i] = (bestName, f.size)
                    shared.append(i)
                } else {
                    out[i] = (own.fontName, own.size)
                }
            }
            // UI text comes in a few fixed sizes: snap near-equal sizes to the median.
            let sizes = shared.map { out[$0]!.1 }.sorted()
            if !sizes.isEmpty {
                let median = sizes[sizes.count / 2]
                for i in shared where abs(out[i]!.1 - median) / median < 0.06 { out[i]!.1 = median }
            }
        }
        return out
    }

    /// Turns rule matches into per-observation edits aligned to whole words.
    static func planEdits(lines: [OCRLine], rules: RuleSet) -> [PlannedEdit] {
        var edits: [PlannedEdit] = []
        for line in lines {
            let matches = rules.matches(in: line.text)
            guard !matches.isEmpty else { continue }
            // Per observation: (local match range, replacement text, match)
            var perPart: [Int: [(NSRange, String, RuleMatch)]] = [:]
            for m in matches {
                var first = true
                for (pi, part) in line.parts.enumerated() {
                    let partRange = NSRange(location: part.offset, length: (part.piece.text as NSString).length)
                    let inter = NSIntersectionRange(m.range, partRange)
                    guard inter.length > 0 else { continue }
                    let local = NSRange(location: inter.location - part.offset, length: inter.length)
                    perPart[pi, default: []].append((local, first ? m.replacement : "", m))
                    first = false
                }
            }
            for pi in perPart.keys.sorted() {
                let piece = line.parts[pi].piece
                let ns = piece.text as NSString
                let items = perPart[pi]!.sorted { $0.0.location < $1.0.location }
                // Expand each match to word boundaries, then merge overlapping spans.
                var groups: [(NSRange, [(NSRange, String, RuleMatch)])] = []
                for it in items {
                    let w = wordRange(ns, it.0)
                    if let last = groups.last, NSMaxRange(last.0) >= w.location {
                        groups[groups.count - 1].0 = NSUnionRange(last.0, w)
                        groups[groups.count - 1].1.append(it)
                    } else {
                        groups.append((w, [it]))
                    }
                }
                for (range, its) in groups {
                    var newText = ""
                    var cursor = its[0].0.location
                    for (r, rep, _) in its {
                        newText += ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
                        newText += rep
                        cursor = NSMaxRange(r)
                    }
                    newText += ns.substring(with: NSRange(location: cursor, length: NSMaxRange(range) - cursor))
                    edits.append(PlannedEdit(piece: piece, range: range, keepPrefix: its[0].0.location - range.location,
                                             newText: newText, matches: its.map(\.2), line: line.text))
                }
            }
        }
        return edits
    }

    static func wordRange(_ ns: NSString, _ r: NSRange) -> NSRange {
        var s = r.location, e = NSMaxRange(r)
        // "|" counts as a boundary: OCR often reads a text cursor or a border as "|",
        // and redrawing it as text would add a glyph that was never there.
        let space = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "|"))
        func isSpace(_ i: Int) -> Bool {
            guard let u = Unicode.Scalar(ns.character(at: i)) else { return false }
            return space.contains(u)
        }
        while s > 0 && !isSpace(s - 1) { s -= 1 }
        while e < ns.length && !isSpace(e) { e += 1 }
        return NSRange(location: s, length: e - s)
    }

    /// Re-reads the output and reports any rule match. Inside redrawn areas it also
    /// reports near-misses of the replaced originals (one edit away).
    public static func verify(_ image: CGImage, rules: RuleSet, originals: [String], redrawn: [PixelRect],
                              scales: [Double]) throws -> [Leak] {
        var leaks: [Leak] = []
        let fuzzyTerms = Set(originals.map { Rule.fold($0) }.filter { $0.count >= 4 }).sorted()
        for scale in scales {
            let lines = OCR.lines(try OCR.recognize(image, scale: scale))
            for line in lines {
                for m in rules.matches(in: line.text) {
                    leaks.append(Leak(text: m.original, line: line.text, rule: m.rule,
                                      box: PixelRect(boxFor(line, m.range)), ocrScale: scale))
                }
                for part in line.parts {
                    let pbox = PixelRect(part.piece.box)
                    guard redrawn.contains(where: { $0.intersects(pbox) }) else { continue }
                    let folded = Rule.fold(part.piece.text)
                    for t in fuzzyTerms where containsNear(folded, t) {
                        if leaks.contains(where: { $0.line == line.text && $0.ocrScale == scale && Rule.fold($0.text) == t }) { continue }
                        leaks.append(Leak(text: t, line: line.text, rule: "near-match of a replaced term",
                                          box: pbox, ocrScale: scale))
                    }
                }
            }
        }
        return leaks
    }

    static func boxFor(_ line: OCRLine, _ r: NSRange) -> CGRect {
        var box: CGRect?
        for part in line.parts {
            let pr = NSRange(location: part.offset, length: (part.piece.text as NSString).length)
            let inter = NSIntersectionRange(r, pr)
            guard inter.length > 0 else { continue }
            let b = part.piece.box(for: NSRange(location: inter.location - part.offset, length: inter.length))
            box = box.map { $0.union(b) } ?? b
        }
        return box ?? line.box
    }

    /// True when `text` has a substring within edit distance 1 of `term` (or contains it).
    static func containsNear(_ text: String, _ term: String) -> Bool {
        if text.contains(term) { return true }
        let a = Array(text.unicodeScalars), t = Array(term.unicodeScalars)
        guard a.count >= t.count - 1 else { return false }
        for len in [t.count - 1, t.count, t.count + 1] where len > 0 && len <= a.count {
            for s in 0...(a.count - len) where levenshtein(Array(a[s..<(s + len)]), t, limit: 1) <= 1 {
                return true
            }
        }
        return false
    }

    static func levenshtein(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar], limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        var prev = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var cur = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...max(1, b.count) where !b.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
