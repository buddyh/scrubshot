import Foundation

/// JSON rules file. See README for the schema.
public struct RulesFile: Codable {
    public struct Detectors: Codable {
        public var email: Bool?
        public var url: Bool?
        public init(email: Bool? = nil, url: Bool? = nil) { self.email = email; self.url = url }
    }

    public struct Spec: Codable {
        public var term: String?
        public var terms: [String]?
        public var regex: String?
        /// Literal replacement text, or "auto" (the default) for a stable fake value.
        /// Regex rules may use $1-style group references.
        public var replace: String?
        public var category: Category?
        public var wholeWord: Bool?
        public var caseSensitive: Bool?

        public init(term: String? = nil, terms: [String]? = nil, regex: String? = nil, replace: String? = nil,
                    category: Category? = nil, wholeWord: Bool? = nil, caseSensitive: Bool? = nil) {
            self.term = term; self.terms = terms; self.regex = regex; self.replace = replace
            self.category = category; self.wholeWord = wholeWord; self.caseSensitive = caseSensitive
        }
    }

    public var detectors: Detectors?
    public var rules: [Spec]?

    public init(detectors: Detectors? = nil, rules: [Spec]? = nil) {
        self.detectors = detectors; self.rules = rules
    }

    public static func load(_ url: URL) throws -> RulesFile {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw ScrubError.rules("cannot read \(url.path): \(error.localizedDescription)")
        }
        do { return try JSONDecoder().decode(RulesFile.self, from: data) } catch {
            throw ScrubError.rules("\(url.path) is not valid rules JSON: \(error)")
        }
    }
}

/// One place a rule matched inside an OCR line.
public struct RuleMatch: Equatable {
    public let range: NSRange
    public let original: String
    public let replacement: String
    public let rule: String
}

public struct Rule {
    public enum Kind { case literal([String]), regex(NSRegularExpression), detector(String, NSRegularExpression) }
    public enum Replacement { case auto(Category), text(String) }

    public let id: String
    public let kind: Kind
    public let replacement: Replacement
    public let caseSensitive: Bool
    let compiled: NSRegularExpression
    /// Literal rules match on folded text (lowercase, OCR look-alikes merged).
    let folded: Bool

    public init(id: String, kind: Kind, replacement: Replacement, wholeWord: Bool = false, caseSensitive: Bool = false) throws {
        self.id = id
        self.kind = kind
        self.replacement = replacement
        self.caseSensitive = caseSensitive
        switch kind {
        case .literal(let terms):
            let alts = terms.filter { !$0.isEmpty }.map { t -> String in
                let base = caseSensitive ? t : Rule.fold(t)
                // Collapse whitespace so a line break joined by OCR still matches.
                return base.split(whereSeparator: \.isWhitespace)
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: "\\s+")
            }
            guard !alts.isEmpty else { throw ScrubError.rules("rule \(id) has no terms") }
            var p = "(?:" + alts.sorted { $0.count > $1.count }.joined(separator: "|") + ")"
            if wholeWord { p = "(?<![\\p{L}\\p{N}_])" + p + "(?![\\p{L}\\p{N}_])" }
            compiled = try NSRegularExpression(pattern: p)
            folded = !caseSensitive
        case .regex(let re), .detector(_, let re):
            compiled = re
            folded = false
        }
    }

    public func matches(in line: String) -> [RuleMatch] {
        let ns = line as NSString
        let haystack = folded ? Rule.fold(line) : line
        var out: [RuleMatch] = []
        for m in compiled.matches(in: haystack, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
            let original = ns.substring(with: m.range)
            // Skip the reserved example domains our own fake values use.
            if case .detector = kind, Rule.isExampleDomain(original) { continue }
            let replacement: String
            switch self.replacement {
            case .text(let t):
                if case .regex = kind {
                    replacement = compiled.replacementString(for: m, in: line, offset: 0, template: t)
                } else {
                    replacement = t
                }
            case .auto(let cat):
                if case .literal(let terms) = kind, let canon = terms.first {
                    // Aliases share the fake value of the first term, reshaped to each match.
                    let fake = Pseudonym.make(for: canon, category: cat, seed: Rule.fold(canon))
                    replacement = Pseudonym.adaptShape(fake, to: original)
                } else {
                    replacement = Pseudonym.make(for: original, category: cat, seed: Rule.fold(original))
                }
            }
            out.append(RuleMatch(range: m.range, original: original, replacement: replacement, rule: id))
        }
        return out
    }

    /// True only when the email or URL host is exactly a reserved example domain,
    /// which is what our own fake values use.
    static func isExampleDomain(_ s: String) -> Bool {
        var host = s.lowercased()
        if let at = host.lastIndex(of: "@") {
            host = String(host[host.index(after: at)...])
        } else {
            if let scheme = host.range(of: "://") { host = String(host[scheme.upperBound...]) }
            if let end = host.firstIndex(where: { "/?#:".contains($0) }) { host = String(host[..<end]) }
            if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        }
        return ["example.com", "example.org", "example.net"].contains(host)
    }

    /// Lowercases ASCII and merges characters OCR often confuses. Keeps UTF-16 length,
    /// so ranges in the folded string are valid in the original.
    public static func fold(_ s: String) -> String {
        var units = Array(s.utf16)
        for i in units.indices {
            switch units[i] {
            case 0x41...0x5A: units[i] += 0x20 // A-Z
            default: break
            }
            switch units[i] {
            case 0x6C, 0x31, 0x7C, 0x21: units[i] = 0x69 // l 1 | ! -> i
            case 0x30: units[i] = 0x6F // 0 -> o
            case 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2212: units[i] = 0x2D // dashes -> -
            default: break
            }
        }
        return String(decoding: units, as: UTF16.self)
    }
}

/// The full set of rules for a run.
public struct RuleSet {
    public var rules: [Rule]

    public init(rules: [Rule] = []) { self.rules = rules }

    public static let emailPattern = "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
    public static let urlPattern =
        "(?:https?://|www\\.)[^\\s<>\"'()]+|\\b[a-z0-9][a-z0-9-]*(?:\\.[a-z0-9-]+)*\\.(?:com|net|org|io|dev|ai|app|co|us|lab|arpa|local|internal|cloud)(?![a-z0-9-])(?:/[^\\s<>\"'()]*)?"

    public static func build(files: [RulesFile], extra: [Rule] = [], emailDetector: Bool? = nil,
                             urlDetector: Bool? = nil) throws -> RuleSet {
        var rules: [Rule] = extra
        var email = false, url = false
        for (fi, f) in files.enumerated() {
            if let d = f.detectors {
                email = d.email ?? email
                url = d.url ?? url
            }
            for (ri, s) in (f.rules ?? []).enumerated() {
                rules.append(try rule(from: s, id: "file\(fi + 1).rule\(ri + 1)"))
            }
        }
        if let e = emailDetector { email = e }
        if let u = urlDetector { url = u }
        if email {
            rules.append(try Rule(id: "detector.email",
                                  kind: .detector("email", NSRegularExpression(pattern: emailPattern)),
                                  replacement: .auto(.email)))
        }
        if url {
            rules.append(try Rule(id: "detector.url",
                                  kind: .detector("url", NSRegularExpression(pattern: urlPattern, options: [.caseInsensitive])),
                                  replacement: .auto(.url)))
        }
        return RuleSet(rules: rules)
    }

    public static func rule(from s: RulesFile.Spec, id: String) throws -> Rule {
        let replacement: Rule.Replacement
        if let r = s.replace, r != "auto" { replacement = .text(r) } else { replacement = .auto(s.category ?? .word) }
        let cs = s.caseSensitive ?? false
        if let re = s.regex {
            if s.term != nil || s.terms != nil { throw ScrubError.rules("\(id): use either regex or term(s), not both") }
            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: re, options: cs ? [] : [.caseInsensitive])
            } catch {
                throw ScrubError.rules("\(id): bad regex \(re)")
            }
            return try Rule(id: id, kind: .regex(regex), replacement: replacement, caseSensitive: cs)
        }
        var terms = s.terms ?? []
        if let t = s.term { terms.insert(t, at: 0) }
        terms = terms.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if terms.isEmpty { throw ScrubError.rules("\(id): needs term, terms or regex") }
        return try Rule(id: id, kind: .literal(terms), replacement: replacement,
                        wholeWord: s.wholeWord ?? false, caseSensitive: cs)
    }

    /// All non-overlapping matches in a line. Earlier start wins, then the longer match,
    /// then the earlier rule.
    public func matches(in line: String) -> [RuleMatch] {
        var all: [(RuleMatch, Int)] = []
        for (i, r) in rules.enumerated() { all += r.matches(in: line).map { ($0, i) } }
        all.sort { a, b in
            if a.0.range.location != b.0.range.location { return a.0.range.location < b.0.range.location }
            if a.0.range.length != b.0.range.length { return a.0.range.length > b.0.range.length }
            return a.1 < b.1
        }
        var out: [RuleMatch] = []
        var end = 0
        for (m, _) in all where m.range.location >= end {
            out.append(m)
            end = m.range.location + m.range.length
        }
        return out
    }
}
