import AppKit
import CoreText
import Foundation
@testable import ScrubshotCore

/// Synthetic screenshots: known text drawn with the system font on flat backgrounds.
enum Fixtures {
    struct Theme {
        let name: String
        let background: Pixel
        let text: Pixel
        let secondary: Pixel
    }

    static let light = Theme(name: "light", background: Pixel(r: 255, g: 255, b: 255),
                             text: Pixel(r: 31, g: 35, b: 40), secondary: Pixel(r: 101, g: 109, b: 118))
    static let dark = Theme(name: "dark", background: Pixel(r: 13, g: 17, b: 23),
                            text: Pixel(r: 230, g: 237, b: 243), secondary: Pixel(r: 139, g: 148, b: 158))
    static let tinted = Theme(name: "tinted", background: Pixel(r: 221, g: 244, b: 255),
                              text: Pixel(r: 9, g: 105, b: 218), secondary: Pixel(r: 31, g: 35, b: 40))
    static let themes = [light, dark, tinted]

    /// Lines of (text, point size, secondary color?).
    static let lines: [(String, CGFloat, Bool)] = [
        ("Deploy the Falcon Console to staging", 15, false),
        ("octo/acme-billing-api  updated 2h ago", 12, true),
        ("Ping jordan.reyes@acme.test about the Q3 rollout", 14, false),
        ("Ticket: Falcon Console times out on login", 13, false),
    ]

    static func color(_ p: Pixel) -> CGColor {
        CGColor(srgbRed: CGFloat(p.r) / 255, green: CGFloat(p.g) / 255, blue: CGFloat(p.b) / 255, alpha: 1)
    }

    /// Renders the fixture at `scale` (1 or 2). Layout is in points.
    static func image(_ theme: Theme, scale: CGFloat) -> CGImage {
        let wPt: CGFloat = 520, hPt: CGFloat = 40 + CGFloat(lines.count) * 34
        let w = Int(wPt * scale), h = Int(hPt * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(color(theme.background))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setShouldSmoothFonts(false)
        for (i, (text, size, secondary)) in lines.enumerated() {
            let font = NSFont.systemFont(ofSize: size * scale) as CTFont
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(secondary ? theme.secondary : theme.text),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
            let baselineFromTop = (36 + CGFloat(i) * 34) * scale
            ctx.textPosition = CGPoint(x: 24 * scale, y: CGFloat(h) - baselineFromTop)
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()!
    }

    static let rules = RulesFile(
        detectors: .init(email: true, url: false),
        rules: [
            .init(term: "Falcon Console", replace: "Harbor Desk"),
            .init(regex: "acme-([a-z]+)-api", replace: "zephyr-$1-api"),
        ])
}
