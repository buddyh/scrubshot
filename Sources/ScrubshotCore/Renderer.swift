import AppKit
import CoreGraphics
import CoreText
import Foundation

/// One region of text to rewrite.
public struct EditRequest {
    /// Vision box of the original text span, in pixels (top-left origin).
    public var box: CGRect
    /// The original text in that box, as OCR read it.
    public var originalText: String
    /// UTF-16 length of a leading part of `originalText` to leave untouched when a clean
    /// cut is possible (e.g. "owner/" in "owner/secret-repo").
    public var keepPrefix: Int
    /// What replaces `originalText` after the kept prefix.
    public var newText: String

    public init(box: CGRect, originalText: String, keepPrefix: Int = 0, newText: String) {
        self.box = box; self.originalText = originalText; self.keepPrefix = keepPrefix; self.newText = newText
    }
}

/// What the renderer did for one edit.
public struct EditResult: Codable {
    public var fill: PixelRect
    public var font: String
    public var fontSize: Double
    public var textColor: String
    public var backgroundColor: String
    public var keptPrefix: Bool
    /// 1.0 means the replacement fit at the matched size; lower means it was shrunk.
    public var scale: Double
    /// New text width minus the original's, in pixels. Positive means the replacement
    /// is wider (it was tightened or shrunk); negative leaves a gap after it.
    public var widthDelta: Double
    public var fitError: Double
    public var warnings: [String]
}

struct FontCandidate {
    let name: String
    let make: (CGFloat) -> CTFont

    static let all: [FontCandidate] = {
        func sys(_ n: String, _ w: NSFont.Weight) -> FontCandidate {
            FontCandidate(name: "SF Pro \(n)") { NSFont.systemFont(ofSize: $0, weight: w) as CTFont }
        }
        func mono(_ n: String, _ w: NSFont.Weight) -> FontCandidate {
            FontCandidate(name: "SF Mono \(n)") { NSFont.monospacedSystemFont(ofSize: $0, weight: w) as CTFont }
        }
        func named(_ display: String, _ ps: String) -> FontCandidate {
            FontCandidate(name: display) { CTFontCreateWithName(ps as CFString, $0, nil) }
        }
        return [
            sys("Regular", .regular), sys("Medium", .medium), sys("Semibold", .semibold), sys("Bold", .bold),
            mono("Regular", .regular), mono("Medium", .medium), mono("Semibold", .semibold),
            named("Helvetica Neue", "HelveticaNeue"), named("Helvetica Neue Bold", "HelveticaNeue-Bold"),
            named("Menlo", "Menlo-Regular"),
        ]
    }()
}

/// Coverage mask, row-major, top-left origin, values 0...1.
struct Mask {
    let rect: PixelRect
    var v: [Float]

    func at(_ x: Int, _ y: Int) -> Float {
        guard rect.contains(x, y) else { return 0 }
        return v[(y - rect.y0) * rect.width + (x - rect.x0)]
    }

    /// Bounding box of cells above `threshold`, in image coordinates.
    func inkBox(_ threshold: Float) -> PixelRect? {
        var x0 = Int.max, y0 = Int.max, x1 = Int.min, y1 = Int.min
        for y in 0..<rect.height {
            for x in 0..<rect.width where v[y * rect.width + x] > threshold {
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        guard x0 != Int.max else { return nil }
        return PixelRect(x0: rect.x0 + x0, y0: rect.y0 + y0, x1: rect.x0 + x1 + 1, y1: rect.y0 + y1 + 1)
    }
}

public enum Renderer {
    static let inkThreshold = 20
    static let blankThreshold = 6

    static func makeLine(_ text: String, font: CTFont, tracking: CGFloat = 0) -> CTLine {
        var attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        if tracking != 0 { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = tracking }
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    /// Renders `line` as a coverage mask over `rect`, with the pen at `origin`
    /// (x = pen position, y = baseline, image coordinates).
    static func render(_ line: CTLine, origin: CGPoint, rect: PixelRect) -> Mask {
        let w = max(1, rect.width), h = max(1, rect.height)
        var buf = [UInt8](repeating: 0, count: w * h)
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true)
            ctx.setAllowsFontSmoothing(false); ctx.setShouldSmoothFonts(false)
            ctx.setAllowsFontSubpixelPositioning(true); ctx.setShouldSubpixelPositionFonts(true)
            ctx.setAllowsFontSubpixelQuantization(false); ctx.setShouldSubpixelQuantizeFonts(false)
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.textPosition = CGPoint(x: origin.x - CGFloat(rect.x0), y: CGFloat(h) - (origin.y - CGFloat(rect.y0)))
            CTLineDraw(line, ctx)
        }
        return Mask(rect: PixelRect(x0: rect.x0, y0: rect.y0, x1: rect.x0 + w, y1: rect.y0 + h),
                    v: buf.map { Float($0) / 255 })
    }

    static func pathBounds(_ line: CTLine) -> CGRect {
        CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    }

    // MARK: sampling

    /// Most common color on the border of `r`, and the share of border pixels close to it.
    static func background(_ bmp: Bitmap, _ r: PixelRect, reference: Pixel? = nil) -> (Pixel, Double) {
        var counts: [Pixel: Int] = [:]
        var border: [Pixel] = []
        func add(_ x: Int, _ y: Int) {
            guard bmp.contains(x, y) else { return }
            let p = bmp[x, y]
            counts[p, default: 0] += 1
            border.append(p)
        }
        for x in r.x0..<r.x1 { add(x, r.y0); add(x, r.y1 - 1) }
        for y in r.y0..<r.y1 { add(r.x0, y); add(r.x1 - 1, y) }
        // Ties break on the packed value so the pick never depends on dictionary order.
        let mode = counts.max { a, b in
            a.value != b.value ? a.value < b.value : pack(a.key) > pack(b.key)
        }?.key ?? Pixel(r: 255, g: 255, b: 255)
        let best = reference ?? mode
        let near = border.filter { $0.distance(to: best) <= 8 }.count
        return (best, border.isEmpty ? 0 : Double(near) / Double(border.count))
    }

    static func pack(_ p: Pixel) -> UInt32 {
        UInt32(p.r) << 24 | UInt32(p.g) << 16 | UInt32(p.b) << 8 | UInt32(p.a)
    }

    static func hex(_ p: Pixel) -> String { String(format: "#%02x%02x%02x", p.r, p.g, p.b) }

    // MARK: analysis

    /// A font candidate placed over the original text.
    public struct Fit {
        let cand: FontCandidate
        public var fontName: String { cand.name }
        public var size: CGFloat
        /// Pen position (x) and baseline (y) of the original text, image coordinates.
        var origin: CGPoint
        public var error: Double
    }

    /// Everything measured about one edit before anything is drawn.
    public struct Analysis {
        public let request: EditRequest
        let bg: Pixel
        let flatness: Double
        public let ink: PixelRect
        let window: PixelRect
        let observed: [Float]
        let fg0: [Double]
        let coverageThreshold: Float
        /// All candidates, best first.
        public var fits: [Fit]

        var flat: Bool { flatness >= 0.85 }
        public func fit(named name: String) -> Fit? { fits.first { $0.cand.name == name } }
    }

    public static func analyze(_ req: EditRequest, in bmp: Bitmap) -> Analysis? {
        let box = req.box
        let h = max(4, box.height)
        let search = bmp.clamp(PixelRect(
            x0: Int((box.minX - 0.4 * h).rounded(.down)), y0: Int((box.minY - 0.45 * h).rounded(.down)),
            x1: Int((box.maxX + 0.4 * h).rounded(.up)), y1: Int((box.maxY + 0.45 * h).rounded(.up))))
        guard !search.isEmpty else { return nil }
        let (bg, _) = background(bmp, search)

        func isInk(_ x: Int, _ y: Int) -> Bool { bmp[x, y].distance(to: bg) > inkThreshold }
        func colInk(_ x: Int, _ y0: Int, _ y1: Int) -> Bool {
            guard x >= 0 && x < bmp.width else { return false }
            for y in y0..<y1 where isInk(x, y) { return true }
            return false
        }
        func rowInk(_ y: Int, _ x0: Int, _ x1: Int) -> Bool {
            guard y >= 0 && y < bmp.height else { return false }
            for x in x0..<x1 where isInk(x, y) { return true }
            return false
        }

        // Ink box: start from the Vision box, trim empty edges, grow into touching ink.
        let vy0 = max(search.y0, Int(box.minY.rounded(.down))), vy1 = min(search.y1, Int(box.maxY.rounded(.up)))
        var x0 = max(search.x0, Int(box.minX.rounded(.down))), x1 = min(search.x1, Int(box.maxX.rounded(.up)))
        while x0 < x1 && !colInk(x0, vy0, vy1) { x0 += 1 }
        while x1 > x0 && !colInk(x1 - 1, vy0, vy1) { x1 -= 1 }
        guard x1 > x0 else { return nil }
        while x0 > search.x0 && colInk(x0 - 1, vy0, vy1) { x0 -= 1 }
        while x1 < search.x1 && colInk(x1, vy0, vy1) { x1 += 1 }
        var y0 = vy0, y1 = vy1
        while y0 < y1 && !rowInk(y0, x0, x1) { y0 += 1 }
        while y1 > y0 && !rowInk(y1 - 1, x0, x1) { y1 -= 1 }
        guard y1 > y0 else { return nil }
        while y0 > search.y0 && rowInk(y0 - 1, x0, x1) { y0 -= 1 }
        while y1 < search.y1 && rowInk(y1, x0, x1) { y1 += 1 }
        let ink = PixelRect(x0: x0, y0: y0, x1: x1, y1: y1)

        // Flatness from a ring two pixels outside the ink.
        let ring = bmp.clamp(PixelRect(x0: ink.x0 - 2, y0: ink.y0 - 2, x1: ink.x1 + 2, y1: ink.y1 + 2))
        let (_, flatness) = background(bmp, ring, reference: bg)

        // First guess at the text color: the strongest ink pixels.
        var inkPixels: [Pixel] = []
        for y in ink.y0..<ink.y1 { for x in ink.x0..<ink.x1 where isInk(x, y) { inkPixels.append(bmp[x, y]) } }
        inkPixels.sort { a, b in
            let da = a.distance(to: bg), db = b.distance(to: bg)
            return da != db ? da > db : pack(a) < pack(b)
        }
        let top = inkPixels.prefix(max(1, inkPixels.count / 5))
        let fg0 = (0..<3).map { c -> Double in
            top.map { Double([$0.r, $0.g, $0.b][c]) }.reduce(0, +) / Double(top.count)
        }
        let bgv = [Double(bg.r), Double(bg.g), Double(bg.b)]
        var dir = zip(fg0, bgv).map { $0 - $1 }
        let dirLen = max(1, sqrt(dir.map { $0 * $0 }.reduce(0, +)))
        dir = dir.map { $0 / dirLen }

        // Observed coverage, projected on the text-color direction.
        let window = bmp.clamp(PixelRect(x0: ink.x0 - 2, y0: ink.y0 - 2, x1: ink.x1 + 2, y1: ink.y1 + 2))
        var observed = [Float](repeating: 0, count: window.width * window.height)
        for y in window.y0..<window.y1 {
            for x in window.x0..<window.x1 {
                let p = bmp[x, y]
                let d = (Double(p.r) - bgv[0]) * dir[0] + (Double(p.g) - bgv[1]) * dir[1] + (Double(p.b) - bgv[2]) * dir[2]
                observed[(y - window.y0) * window.width + (x - window.x0)] = Float(max(0, d))
            }
        }
        var a = Analysis(request: req, bg: bg, flatness: flatness, ink: ink, window: window, observed: observed,
                         fg0: fg0, coverageThreshold: Float(min(0.5, max(0.05, Double(inkThreshold) / dirLen))),
                         fits: [])
        var fits: [Fit] = []
        for cand in FontCandidate.all {
            if let f = fit(a, cand, size: nil) { fits.append(f) }
        }
        fits.sort { $0.error != $1.error ? $0.error < $1.error : $0.cand.name < $1.cand.name }
        guard !fits.isEmpty else { return nil }
        a.fits = fits
        return a
    }

    /// How well `line` drawn at `origin` explains the observed pixels. 0 is perfect.
    static func score(_ a: Analysis, _ line: CTLine, _ origin: CGPoint) -> Double {
        let m = render(line, origin: origin, rect: a.window)
        var sdc = 0.0, sdd = 0.0, scc = 0.0
        for i in 0..<a.observed.count {
            let d = Double(a.observed[i]), c = Double(m.v[i])
            sdc += d * c; sdd += d * d; scc += c * c
        }
        guard sdd > 0, scc > 0 else { return 1 }
        return 1 - (sdc * sdc) / (sdd * scc)
    }

    /// Places `cand` over the original text. With `size` nil the size comes from the
    /// ink width; otherwise the given size is kept. Then aligns to the ink and refines
    /// the position to a quarter pixel.
    static func fit(_ a: Analysis, _ cand: FontCandidate, size fixed: CGFloat?, refine: Bool = false) -> Fit? {
        let ink = a.ink
        let text = a.request.originalText
        var size = fixed ?? CGFloat(ink.height) * 1.1
        var origin = CGPoint.zero
        var heightRatio = 1.0
        var placed = false
        for iter in 0..<6 {
            let line = makeLine(text, font: cand.make(size))
            let pb = pathBounds(line)
            if !placed { origin = CGPoint(x: CGFloat(ink.x0) - pb.minX, y: CGFloat(ink.y1) + pb.minY) }
            let pad = Int(size) + 4
            let area = PixelRect(x0: ink.x0 - pad, y0: ink.y0 - pad, x1: ink.x1 + pad + Int(size), y1: ink.y1 + pad)
            let m = render(line, origin: origin, rect: area)
            guard let r = m.inkBox(a.coverageThreshold), r.width > 0 else { return nil }
            origin.x += CGFloat(ink.x0 - r.x0)
            origin.y += CGFloat(ink.y0 + ink.y1 - r.y0 - r.y1) / 2
            placed = true
            heightRatio = Double(r.height) / Double(ink.height)
            let ratio = CGFloat(ink.width) / CGFloat(r.width)
            if fixed != nil || abs(ratio - 1) < 0.004 || iter == 5 { break }
            size *= ratio
        }
        guard size > 2, size < 4 * CGFloat(ink.height) + 8 else { return nil }
        let line = makeLine(text, font: cand.make(size))
        // Sub-pixel alignment: match the coverage centroid of the observed pixels.
        let oc = centroid(a.observed, a.window)
        for _ in 0..<2 {
            let m = render(line, origin: origin, rect: a.window)
            guard let oc, let rc = centroid(m.v, a.window) else { break }
            origin.x += oc.x - rc.x
            origin.y += oc.y - rc.y
        }
        var bestE = score(a, line, origin), bestO = origin
        let step = refine ? 0.125 : 0.25
        let span = refine ? 0.375 : 0.25
        do {
            for dy in stride(from: -span, through: span, by: step) {
                for dx in stride(from: -span, through: span, by: step) where dx != 0 || dy != 0 {
                    let o = CGPoint(x: origin.x + dx, y: origin.y + dy)
                    let e = score(a, line, o)
                    if e < bestE - 1e-9 { bestE = e; bestO = o }
                }
            }
        }
        bestE += 0.5 * abs(log(max(0.2, heightRatio)))
        return Fit(cand: cand, size: size, origin: bestO, error: bestE)
    }

    static func centroid(_ v: [Float], _ r: PixelRect) -> CGPoint? {
        var sx = 0.0, sy = 0.0, sw = 0.0
        for y in 0..<r.height {
            for x in 0..<r.width {
                let w = Double(v[y * r.width + x])
                sx += w * Double(x); sy += w * Double(y); sw += w
            }
        }
        guard sw > 0 else { return nil }
        return CGPoint(x: sx / sw, y: sy / sw)
    }

    /// Final placement for a chosen font and size.
    public static func place(_ a: Analysis, fontName: String, size: CGFloat?) -> Fit? {
        guard let cand = FontCandidate.all.first(where: { $0.name == fontName }) else { return nil }
        return fit(a, cand, size: size, refine: true)
    }

    // MARK: drawing

    public static func draw(_ a: Analysis, fit best: Fit, into bmp: Bitmap) -> EditResult {
        var warnings: [String] = []
        let req = a.request
        let bg = a.bg, ink = a.ink, window = a.window
        let bgv = [Double(bg.r), Double(bg.g), Double(bg.b)]
        if !a.flat {
            warnings.append(String(format: "background is not flat (%.0f%% uniform); filled with a row blend", a.flatness * 100))
        }
        func colBlank(_ x: Int, _ y0: Int, _ y1: Int) -> Bool {
            guard x >= 0 && x < bmp.width else { return false }
            for y in y0..<y1 where bmp[x, y].distance(to: bg) > blankThreshold { return false }
            return true
        }

        let font = best.cand.make(best.size)
        let origLine = makeLine(req.originalText, font: font)
        if best.error > 0.35 { warnings.append(String(format: "font match is weak (error %.2f)", best.error)) }

        // Text color by least squares against the fitted coverage.
        let fitMask = render(origLine, origin: best.origin, rect: window)
        var num = [0.0, 0.0, 0.0], den = 0.0
        for y in window.y0..<window.y1 {
            for x in window.x0..<window.x1 {
                let c = Double(fitMask.at(x, y))
                guard c > 0.05 else { continue }
                let p = bmp[x, y]
                num[0] += c * (Double(p.r) - bgv[0]); num[1] += c * (Double(p.g) - bgv[1]); num[2] += c * (Double(p.b) - bgv[2])
                den += c * c
            }
        }
        func channel(_ i: Int) -> UInt8 {
            let v = den > 0 ? bgv[i] + num[i] / den : a.fg0[i]
            return UInt8(max(0, min(255, v.rounded())))
        }
        let fg = Pixel(r: channel(0), g: channel(1), b: channel(2))

        // Fill rectangle: the ink plus one pixel of anti-aliasing.
        var fill = bmp.clamp(PixelRect(x0: ink.x0 - 1, y0: ink.y0 - 1, x1: ink.x1 + 1, y1: ink.y1 + 1))
        var penX = best.origin.x
        var text = (req.originalText as NSString).substring(to: req.keepPrefix) + req.newText
        var keptPrefix = false
        if req.keepPrefix > 0 && req.keepPrefix < (req.originalText as NSString).length {
            let cut = best.origin.x + CTLineGetOffsetForStringIndex(origLine, req.keepPrefix, nil)
            let reach = Int((0.35 * best.size).rounded(.up))
            let c = Int(cut.rounded())
            var found: Int?
            search: for d in 0...reach {
                for x in [c - d, c + d] where x > ink.x0 && x < ink.x1 && colBlank(x, fill.y0, fill.y1) {
                    found = x
                    break search
                }
            }
            if let col = found {
                fill.x0 = col
                penX = cut
                text = req.newText
                keptPrefix = true
            }
        }

        // Room to the right: blank columns up to the next ink, keeping a word gap.
        let gap = max(2, Int((0.3 * best.size).rounded()))
        let cap = max(Int(2 * best.size), ink.width / 3)
        var right = ink.x1
        while right < min(bmp.width, ink.x1 + cap) && colBlank(right, fill.y0, fill.y1) { right += 1 }
        let hitInk = right < min(bmp.width, ink.x1 + cap)
        let maxRight = CGFloat(hitInk ? max(ink.x1, right - gap) : right)

        // Fit the new text, tightening then shrinking if it is too wide.
        var size = best.size
        var tracking: CGFloat = 0
        var newLine = makeLine(text, font: font)
        var nb = pathBounds(newLine)
        let naturalRight = penX + nb.maxX
        let n = max(1, text.count - 1)
        if penX + nb.maxX > maxRight && !text.isEmpty {
            let over = penX + nb.maxX - maxRight
            tracking = -min(over / CGFloat(n), 0.04 * size)
            newLine = makeLine(text, font: font, tracking: tracking)
            nb = pathBounds(newLine)
            if penX + nb.maxX > maxRight {
                let f = max(0.5, (maxRight - penX) / max(1, nb.maxX))
                size = best.size * f
                tracking *= f
                newLine = makeLine(text, font: best.cand.make(size), tracking: tracking)
                nb = pathBounds(newLine)
            }
        }
        let scale = Double(size / best.size)
        if scale < 0.9 { warnings.append(String(format: "replacement shrunk to %.0f%% to fit", scale * 100)) }

        // Grow the fill over blank space where the new glyphs land (descenders, longer text).
        let baseline = best.origin.y
        let need = PixelRect(CGRect(x: penX + nb.minX - 1, y: baseline - nb.maxY - 1,
                                    width: nb.width + 2, height: nb.height + 2))
        while fill.x1 < min(Int(maxRight.rounded(.up)) + 1, need.x1) && colBlank(fill.x1, fill.y0, fill.y1) { fill.x1 += 1 }
        func rowBlank(_ y: Int) -> Bool {
            guard y >= 0 && y < bmp.height else { return false }
            for x in fill.x0..<fill.x1 where bmp[x, y].distance(to: bg) > blankThreshold { return false }
            return true
        }
        while fill.y0 > need.y0 && rowBlank(fill.y0 - 1) { fill.y0 -= 1 }
        while fill.y1 < need.y1 && rowBlank(fill.y1) { fill.y1 += 1 }
        fill = bmp.clamp(fill)

        // Erase.
        for y in fill.y0..<fill.y1 {
            if a.flat {
                for x in fill.x0..<fill.x1 { bmp[x, y] = bg }
            } else {
                let l = bmp.contains(fill.x0 - 1, y) ? bmp[fill.x0 - 1, y] : bg
                let r = bmp.contains(fill.x1, y) ? bmp[fill.x1, y] : bg
                let w = Double(fill.width + 1)
                for x in fill.x0..<fill.x1 {
                    let t = Double(x - fill.x0 + 1) / w
                    func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) * (1 - t) + Double(b) * t).rounded()) }
                    bmp[x, y] = Pixel(r: mix(l.r, r.r), g: mix(l.g, r.g), b: mix(l.b, r.b), a: mix(l.a, r.a))
                }
            }
        }

        // Draw, clipped to the fill rectangle.
        if !text.isEmpty {
            let m = render(newLine, origin: CGPoint(x: penX, y: baseline), rect: fill)
            for y in fill.y0..<fill.y1 {
                for x in fill.x0..<fill.x1 {
                    let cov = Double(m.at(x, y))
                    guard cov > 0 else { continue }
                    let p = bmp[x, y]
                    func mix(_ b: UInt8, _ f: UInt8) -> UInt8 { UInt8((Double(b) * (1 - cov) + Double(f) * cov).rounded()) }
                    bmp[x, y] = Pixel(r: mix(p.r, fg.r), g: mix(p.g, fg.g), b: mix(p.b, fg.b), a: p.a)
                }
            }
        }

        return EditResult(fill: fill, font: best.cand.name, fontSize: Double((best.size * 100).rounded() / 100),
                          textColor: hex(fg), backgroundColor: hex(bg), keptPrefix: keptPrefix, scale: scale,
                          widthDelta: ((naturalRight - CGFloat(ink.x1)) * 10).rounded() / 10,
                          fitError: (best.error * 1000).rounded() / 1000, warnings: warnings)
    }

    /// Analyze, pick the best font, draw. For one-off edits; the scrubber uses
    /// `analyze` + `place` + `draw` so it can agree on one font across a screenshot.
    public static func apply(_ req: EditRequest, to bmp: Bitmap) -> EditResult? {
        guard let a = analyze(req, in: bmp), let f = place(a, fontName: a.fits[0].fontName, size: a.fits[0].size) else {
            return nil
        }
        return draw(a, fit: f, into: bmp)
    }
}
