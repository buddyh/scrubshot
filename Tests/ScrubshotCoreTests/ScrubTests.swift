import CoreGraphics
import Foundation
import XCTest
@testable import ScrubshotCore

final class ScrubTests: XCTestCase {
    func ocrText(_ image: CGImage, scale: Double = 1) throws -> String {
        try OCR.lines(OCR.recognize(image, scale: scale)).map(\.text).joined(separator: "\n")
    }

    func run(_ theme: Fixtures.Theme, scale: CGFloat) throws -> (CGImage, ScrubResult) {
        let img = Fixtures.image(theme, scale: scale)
        let rules = try RuleSet.build(files: [Fixtures.rules])
        return (img, try Scrubber.scrub(img, options: ScrubOptions(rules: rules)))
    }

    func testReplacesTermsOnEveryThemeAndScale() throws {
        for theme in Fixtures.themes {
            for scale: CGFloat in [1, 2] {
                let label = "\(theme.name) @\(Int(scale))x"
                let (_, result) = try run(theme, scale: scale)
                XCTAssertEqual(result.leaks, [], label)
                let originals = result.replacements.map(\.original)
                XCTAssertEqual(originals.filter { $0 == "Falcon Console" }.count, 2, label)
                XCTAssertTrue(originals.contains("acme-billing-api"), label)
                XCTAssertTrue(originals.contains("jordan.reyes@acme.test"), label)

                let text = try ocrText(result.image, scale: scale == 1 ? 2 : 1)
                XCTAssertFalse(text.localizedCaseInsensitiveContains("Falcon"), "\(label): \(text)")
                XCTAssertFalse(text.contains("acme-billing"), "\(label): \(text)")
                XCTAssertFalse(text.contains("jordan.reyes"), "\(label): \(text)")
                XCTAssertTrue(text.contains("Deploy the Harbor Desk to staging"), "\(label): \(text)")
                XCTAssertTrue(text.contains("octo/zephyr-billing-api"), "\(label): \(text)")
                XCTAssertTrue(text.contains("Harbor Desk times out on login"), "\(label): \(text)")
                // The surrounding text must survive untouched.
                XCTAssertTrue(text.contains("about the Q3 rollout"), "\(label): \(text)")
            }
        }
    }

    func testOnlyPixelsInsideFillBoxesChange() throws {
        for theme in Fixtures.themes {
            let (img, result) = try run(theme, scale: 2)
            let a = try Bitmap(image: img), b = try Bitmap(image: result.image)
            let fills = result.replacements.compactMap { $0.render?.fill }
            XCTAssertFalse(fills.isEmpty)
            var changed = 0, outside = 0
            for y in 0..<a.height {
                for x in 0..<a.width where a[x, y] != b[x, y] {
                    changed += 1
                    if !fills.contains(where: { $0.contains(x, y) }) { outside += 1 }
                }
            }
            XCTAssertGreaterThan(changed, 100, theme.name)
            XCTAssertEqual(outside, 0, theme.name)
        }
    }

    func testRenderMatchesSourceStyle() throws {
        for theme in Fixtures.themes {
            let (_, result) = try run(theme, scale: 2)
            for r in result.replacements {
                guard let e = r.render else { return XCTFail("\(r.original) not rendered") }
                XCTAssertTrue(e.font.hasPrefix("SF Pro"), "\(theme.name) \(r.original): \(e.font)")
                XCTAssertEqual(e.backgroundColor, Renderer.hex(theme.background), "\(theme.name) \(r.original)")
                XCTAssertLessThan(e.fitError, 0.1, "\(theme.name) \(r.original)")
            }
        }
    }

    func testOutputIsByteIdenticalAcrossRuns() throws {
        let (_, r1) = try run(Fixtures.dark, scale: 1)
        let (_, r2) = try run(Fixtures.dark, scale: 1)
        XCTAssertEqual(try ImageFile.pngData(r1.image, dpi: nil), try ImageFile.pngData(r2.image, dpi: nil))
    }

    func testVerifyFlagsUnscrubbedImage() throws {
        let img = Fixtures.image(Fixtures.light, scale: 1)
        let rules = try RuleSet.build(files: [Fixtures.rules])
        let leaks = try Scrubber.verify(img, rules: rules, originals: [], redrawn: [], scales: [1])
        XCTAssertTrue(leaks.contains { $0.text == "Falcon Console" })
        XCTAssertTrue(leaks.contains { $0.text.contains("acme-billing-api") })
    }

    func testFailsClosedWhenReplacementStillMatches() throws {
        let img = Fixtures.image(Fixtures.light, scale: 2)
        // The replacement contains the term, so the term stays readable.
        let rules = try RuleSet.build(files: [RulesFile(rules: [.init(term: "Falcon", replace: "Falcon")])])
        let result = try Scrubber.scrub(img, options: ScrubOptions(rules: rules))
        XCTAssertFalse(result.leaks.isEmpty)
    }

    func testStripsMetadataButKeepsPixels() throws {
        let img = Fixtures.image(Fixtures.tinted, scale: 1)
        let data = try ImageFile.pngData(img, dpi: (144, 144))
        let types = ImageFile.chunkTypes(data)
        XCTAssertFalse(types.contains("eXIf"))
        XCTAssertFalse(types.contains("iTXt"))
        XCTAssertFalse(types.contains("tEXt"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scrubshot-roundtrip-\(UUID()).png")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let back = try Bitmap(image: ImageFile.load(url).image)
        XCTAssertEqual(back.data, try Bitmap(image: img).data)
        XCTAssertEqual(try ImageFile.load(url).dpi?.0, 144)
    }

    /// Writes the fixtures to Tests/Fixtures when SCRUBSHOT_WRITE_FIXTURES is set.
    func testWriteFixturesWhenAsked() throws {
        guard ProcessInfo.processInfo.environment["SCRUBSHOT_WRITE_FIXTURES"] != nil else { return }
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for theme in Fixtures.themes {
            for scale: CGFloat in [1, 2] {
                let url = dir.appendingPathComponent("\(theme.name)@\(Int(scale))x.png")
                try ImageFile.writePNG(Fixtures.image(theme, scale: scale), dpi: (72 * Double(scale), 72 * Double(scale)), to: url)
            }
        }
    }
}
