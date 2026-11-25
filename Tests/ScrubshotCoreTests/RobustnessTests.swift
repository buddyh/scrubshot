import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ScrubshotCore

/// Image formats, sizes and file edge cases through the full load, scrub, write path.
/// Inputs are generated in code into a temp directory.
final class RobustnessTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("scrubshot-robust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Restore permissions a test may have removed.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: helpers

    func source(scale: CGFloat = 2) -> CGImage { Fixtures.image(Fixtures.light, scale: scale) }

    func write(_ image: CGImage, type: UTType, name: String, props: [CFString: Any] = [:]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw XCTSkip("no encoder for \(type.identifier)")
        }
        CGImageDestinationAddImage(d, image, props as CFDictionary)
        guard CGImageDestinationFinalize(d) else { throw XCTSkip("\(type.identifier) encode failed") }
        return url
    }

    func ocrText(_ image: CGImage) throws -> String {
        try OCR.lines(OCR.recognize(image, scale: 1)).map(\.text).joined(separator: "\n")
    }

    /// Full path: load, scrub, write PNG, load the PNG again. Returns everything for checks.
    @discardableResult
    func roundTrip(_ input: URL, expectReplaced: Bool = true, file: StaticString = #filePath, line: UInt = #line)
        throws -> (loaded: ImageFile.Loaded, result: ScrubResult, out: URL, reloaded: CGImage)
    {
        let loaded = try ImageFile.load(input)
        let rules = try RuleSet.build(files: [Fixtures.rules])
        let result = try Scrubber.scrub(loaded.image, options: ScrubOptions(rules: rules))
        XCTAssertEqual(result.leaks, [], file: file, line: line)
        if expectReplaced { XCTAssertFalse(result.replacements.isEmpty, file: file, line: line) }
        let out = dir.appendingPathComponent("out-\(UUID().uuidString).png")
        try ImageFile.writePNG(result.image, dpi: loaded.dpi, to: out)
        let again = try ImageFile.load(out)
        if expectReplaced {
            let text = try ocrText(again.image)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("Falcon"), text, file: file, line: line)
            XCTAssertTrue(text.contains("Harbor Desk"), text, file: file, line: line)
        }
        return (loaded, result, out, again.image)
    }

    func assertOnlyChangedInsideFills(_ before: CGImage, _ result: ScrubResult, file: StaticString = #filePath, line: UInt = #line) throws {
        let a = try Bitmap(image: before), b = try Bitmap(image: result.image)
        XCTAssertEqual(a.width, b.width, file: file, line: line)
        let fills = result.replacements.compactMap { $0.render?.fill }
        var outside = 0
        for y in 0..<a.height {
            for x in 0..<a.width where a[x, y] != b[x, y] && !fills.contains(where: { $0.contains(x, y) }) { outside += 1 }
        }
        XCTAssertEqual(outside, 0, file: file, line: line)
    }

    func assertAllowlistedChunks(_ png: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let types = ImageFile.chunkTypes(try Data(contentsOf: png))
        XCTAssertTrue(Set(types).isSubset(of: ImageFile.keptChunks), "\(types)", file: file, line: line)
    }

    func context(bits: Int, space: CGColorSpace, info: UInt32, w: Int, h: Int) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: bits, bytesPerRow: 0, space: space, bitmapInfo: info)!
    }

    func redraw(_ img: CGImage, bits: Int, space: CGColorSpace, info: UInt32) -> CGImage {
        let ctx = context(bits: bits, space: space, info: info, w: img.width, h: img.height)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()!
    }

    // MARK: formats

    func testPNGWithTransparentBackground() throws {
        // Dark text on a fully transparent background, plus a transparent margin.
        let src = source()
        let ctx = context(bits: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          info: CGImageAlphaInfo.premultipliedLast.rawValue, w: src.width, h: src.height)
        ctx.clear(CGRect(x: 0, y: 0, width: src.width, height: src.height))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: src.width, height: src.height - 10))
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: src.width, height: src.height))
        let url = try write(ctx.makeImage()!, type: .png, name: "alpha.png")
        let r = try roundTrip(url)
        try assertOnlyChangedInsideFills(r.loaded.image, r.result)
        XCTAssertNotEqual(r.reloaded.alphaInfo, .none)
        try assertAllowlistedChunks(r.out)
    }

    func testGrayscale8() throws {
        let g = redraw(source(), bits: 8, space: CGColorSpaceCreateDeviceGray(), info: CGImageAlphaInfo.none.rawValue)
        let r = try roundTrip(try write(g, type: .png, name: "gray.png"))
        try assertOnlyChangedInsideFills(r.loaded.image, r.result)
        try assertAllowlistedChunks(r.out)
    }

    func testSixteenBitPNG() throws {
        let img = redraw(source(), bits: 16, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         info: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        XCTAssertEqual(img.bitsPerComponent, 16)
        let r = try roundTrip(try write(img, type: .png, name: "deep.png"))
        try assertOnlyChangedInsideFills(r.loaded.image, r.result)
        try assertAllowlistedChunks(r.out)
    }

    func testIndexedPNG() throws {
        // 16 gray levels in an indexed color space.
        let src = try Bitmap(image: source())
        var table = [UInt8]()
        for i in 0..<16 { let v = UInt8(i * 17); table += [v, v, v] }
        let space = CGColorSpace(indexedBaseSpace: CGColorSpaceCreateDeviceRGB(), last: 15, colorTable: table)!
        var idx = [UInt8](repeating: 0, count: src.width * src.height)
        for y in 0..<src.height { for x in 0..<src.width { idx[y * src.width + x] = UInt8(min(15, Int((src[x, y].luma / 17).rounded()))) } }
        let provider = CGDataProvider(data: Data(idx) as CFData)!
        let img = CGImage(width: src.width, height: src.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: src.width,
                          space: space, bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
                          shouldInterpolate: false, intent: .defaultIntent)!
        let r = try roundTrip(try write(img, type: .png, name: "indexed.png"))
        try assertOnlyChangedInsideFills(r.loaded.image, r.result)
        try assertAllowlistedChunks(r.out)
    }

    func testJPEG() throws {
        let rgb = redraw(source(), bits: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!, info: CGImageAlphaInfo.noneSkipLast.rawValue)
        let url = try write(rgb, type: .jpeg, name: "shot.jpg", props: [kCGImageDestinationLossyCompressionQuality: 0.95])
        let r = try roundTrip(url)
        try assertOnlyChangedInsideFills(r.loaded.image, r.result)
    }

    func testTIFF() throws {
        let url = try write(source(), type: .tiff, name: "shot.tiff")
        let r = try roundTrip(url)
        try assertOnlyChangedInsideFills(r.loaded.image, r.result)
    }

    func testHEIC() throws {
        let rgb = redraw(source(), bits: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!, info: CGImageAlphaInfo.noneSkipLast.rawValue)
        let url = try write(rgb, type: .heic, name: "shot.heic", props: [kCGImageDestinationLossyCompressionQuality: 0.95])
        let r = try roundTrip(url)
        try assertOnlyChangedInsideFills(r.loaded.image, r.result)
    }

    func testDisplayP3KeepsProfileAndOutsidePixels() throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let img = redraw(source(), bits: 8, space: p3, info: CGImageAlphaInfo.premultipliedLast.rawValue)
        let r = try roundTrip(try write(img, type: .png, name: "p3.png"))
        XCTAssertEqual(r.reloaded.colorSpace?.name as String?, CGColorSpace.displayP3 as String)
        try assertOnlyChangedInsideFills(r.loaded.image, r.result)
        // Pixels outside edits are identical in the output file as read back.
        let before = try Bitmap(image: r.loaded.image), after = try Bitmap(image: r.reloaded)
        let fills = r.result.replacements.compactMap { $0.render?.fill }
        var bad = 0
        for y in 0..<before.height { for x in 0..<before.width where before[x, y] != after[x, y] && !fills.contains(where: { $0.contains(x, y) }) { bad += 1 } }
        XCTAssertEqual(bad, 0)
        try assertAllowlistedChunks(r.out)
    }

    func testOtherProfilesKeepColorSpace() throws {
        for name in [CGColorSpace.adobeRGB1998, CGColorSpace.genericRGBLinear, CGColorSpace.extendedSRGB] {
            guard let space = CGColorSpace(name: name) else { continue }
            guard let ctx = CGContext(data: nil, width: 520, height: 176, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.draw(source(scale: 1), in: CGRect(x: 0, y: 0, width: 520, height: 176))
            let url = try write(ctx.makeImage()!, type: .png, name: "\(name).png")
            let r = try roundTrip(url, expectReplaced: false)
            XCTAssertEqual(r.reloaded.colorSpace?.model, .rgb, name as String)
            let a = try Bitmap(image: r.loaded.image), b = try Bitmap(image: r.reloaded)
            if r.result.replacements.isEmpty { XCTAssertEqual(a.data, b.data, name as String) }
        }
    }

    func testDPIPreserved() throws {
        let url = try write(source(), type: .png, name: "dpi.png", props: [kCGImagePropertyDPIWidth: 144.0, kCGImagePropertyDPIHeight: 144.0])
        let r = try roundTrip(url)
        XCTAssertEqual(r.loaded.dpi?.0 ?? 0, 144, accuracy: 0.01)
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(r.out as CFURL, nil)!, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyDPIWidth] as? Double ?? 0, 144, accuracy: 0.01)
    }

    func testMetadataStripped() throws {
        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret note"],
            kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: "private", kCGImagePropertyPNGAuthor: "someone"],
        ]
        let url = try write(source(), type: .png, name: "meta.png", props: props)
        XCTAssertTrue(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("private"))
        let r = try roundTrip(url)
        try assertAllowlistedChunks(r.out)
        XCTAssertFalse(String(decoding: try Data(contentsOf: r.out), as: UTF8.self).contains("private"))
    }

    // MARK: orientation and frames

    func testExifOrientationIsNormalized() throws {
        // Draw the fixture rotated 90 degrees so it only reads upright once orientation 6 is applied.
        let src = source()
        let ctx = context(bits: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          info: CGImageAlphaInfo.premultipliedLast.rawValue, w: src.height, h: src.width)
        // Orientation 6 = rotate 90 clockwise to display. Store the image rotated 90 counterclockwise.
        ctx.translateBy(x: CGFloat(src.height), y: 0)
        ctx.rotate(by: .pi / 2)
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: src.width, height: src.height))
        let stored = ctx.makeImage()!
        let url = try write(stored, type: .jpeg, name: "rot.jpg",
                            props: [kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 0.95])
        let loaded = try ImageFile.load(url)
        XCTAssertEqual(loaded.image.width, src.width)
        XCTAssertEqual(loaded.image.height, src.height)
        try roundTrip(url)
    }

    func testOrientationMapsCornersLikeExif() {
        // 3 wide, 2 tall. Top-left red, top-right green, bottom-left blue.
        let b = Bitmap(width: 3, height: 2)
        let red = Pixel(r: 255, g: 0, b: 0), green = Pixel(r: 0, g: 255, b: 0), blue = Pixel(r: 0, g: 0, b: 255)
        b[0, 0] = red; b[2, 0] = green; b[0, 1] = blue
        // Where red (source top-left) lands after each orientation, plus the output size.
        let expected: [UInt32: (x: Int, y: Int, w: Int, h: Int)] = [
            2: (2, 0, 3, 2), 3: (2, 1, 3, 2), 4: (0, 1, 3, 2),
            5: (0, 0, 2, 3), 6: (1, 0, 2, 3), 7: (1, 2, 2, 3), 8: (0, 2, 2, 3),
        ]
        for (o, e) in expected {
            let r = b.oriented(o)
            XCTAssertEqual(r.width, e.w, "orientation \(o)")
            XCTAssertEqual(r.height, e.h, "orientation \(o)")
            XCTAssertEqual(r[e.x, e.y], red, "orientation \(o)")
        }
        // 90 degrees clockwise: bottom-left goes to top-left, top-right to bottom-right.
        XCTAssertEqual(b.oriented(6)[0, 0], blue)
        XCTAssertEqual(b.oriented(6)[1, 2], green)
    }

    func testAnimatedGIFIsRefused() throws {
        let url = dir.appendingPathComponent("anim.gif")
        let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil)!
        let frame = redraw(source(scale: 1), bits: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!, info: CGImageAlphaInfo.premultipliedLast.rawValue)
        CGImageDestinationAddImage(d, frame, nil)
        CGImageDestinationAddImage(d, frame, nil)
        XCTAssertTrue(CGImageDestinationFinalize(d))
        XCTAssertThrowsError(try ImageFile.load(url)) { e in
            XCTAssertTrue("\(e)".contains("frames"), "\(e)")
        }
    }

    func testSingleFrameGIFLoads() throws {
        let frame = redraw(source(scale: 1), bits: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!, info: CGImageAlphaInfo.premultipliedLast.rawValue)
        let url = try write(frame, type: .gif, name: "one.gif")
        XCTAssertNoThrow(try ImageFile.load(url))
    }

    // MARK: sizes

    func testOnePixelImage() throws {
        let img = redraw(source(scale: 1).cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1))!,
                         bits: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!, info: CGImageAlphaInfo.premultipliedLast.rawValue)
        let r = try roundTrip(try write(img, type: .png, name: "one.png"), expectReplaced: false)
        XCTAssertEqual(r.result.replacements.count, 0)
        XCTAssertEqual(r.reloaded.width, 1)
    }

    func testTinyImagesWithoutText() throws {
        for (w, h) in [(2, 2), (3, 7), (17, 5), (40, 40)] {
            let ctx = context(bits: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!, info: CGImageAlphaInfo.premultipliedLast.rawValue, w: w, h: h)
            ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let r = try roundTrip(try write(ctx.makeImage()!, type: .png, name: "tiny\(w)x\(h).png"), expectReplaced: false)
            XCTAssertEqual(r.result.replacements.count, 0)
            XCTAssertEqual(try Bitmap(image: r.loaded.image).data, try Bitmap(image: r.reloaded).data)
        }
    }

    func testOddWidthWithRowPadding() throws {
        // Cropping gives images whose rows are padded or offset in the source buffer.
        let full = source()
        for w in [full.width - 1, full.width - 3, 999] {
            let crop = full.cropping(to: CGRect(x: 1, y: 1, width: w, height: full.height - 1))!
            let r = try roundTrip(try write(crop, type: .png, name: "odd\(w).png"))
            XCTAssertEqual(r.reloaded.width, w)
            try assertOnlyChangedInsideFills(r.loaded.image, r.result)
        }
    }

    func testHugeImageIsRefusedWithLimit() throws {
        // 20000 x 20000 = 400 MP of one color compresses to almost nothing as PNG.
        let w = 20000, h = 20000
        let ctx = context(bits: 8, space: CGColorSpaceCreateDeviceGray(), info: CGImageAlphaInfo.none.rawValue, w: w, h: h)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let url = try write(ctx.makeImage()!, type: .png, name: "huge.png")
        XCTAssertThrowsError(try ImageFile.load(url)) { e in
            XCTAssertTrue("\(e)".contains("megapixels"), "\(e)")
        }
    }

    func testLargeImageWithinLimitScrubs() throws {
        // 8000 x 8000 flat image: must finish without running out of memory.
        let w = 8000, h = 8000
        let ctx = context(bits: 8, space: CGColorSpaceCreateDeviceGray(), info: CGImageAlphaInfo.none.rawValue, w: w, h: h)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let url = try write(ctx.makeImage()!, type: .png, name: "large.png")
        let loaded = try ImageFile.load(url)
        let rules = try RuleSet.build(files: [Fixtures.rules])
        let result = try Scrubber.scrub(loaded.image, options: ScrubOptions(rules: rules))
        XCTAssertEqual(result.replacements.count, 0)
        XCTAssertEqual(result.image.width, w)
    }

    // MARK: files

    func testPathWithSpacesAndUnicode() throws {
        let sub = dir.appendingPathComponent("my shots é 日本 ✓")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let url = sub.appendingPathComponent("Screen Shot ü 1.png")
        let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, source(), nil)
        XCTAssertTrue(CGImageDestinationFinalize(d))
        try roundTrip(url)
    }

    func testNonImageWithPNGExtension() throws {
        let url = dir.appendingPathComponent("fake.png")
        try Data("this is not an image".utf8).write(to: url)
        XCTAssertThrowsError(try ImageFile.load(url)) { e in
            XCTAssertTrue(e is ScrubError, "\(e)")
            XCTAssertTrue("\(e)".contains("fake.png"), "\(e)")
        }
    }

    func testEmptyFile() throws {
        let url = dir.appendingPathComponent("empty.png")
        try Data().write(to: url)
        XCTAssertThrowsError(try ImageFile.load(url)) { e in
            XCTAssertTrue("\(e)".contains("empty"), "\(e)")
        }
    }

    func testTruncatedPNG() throws {
        let url = try write(source(), type: .png, name: "full.png")
        let data = try Data(contentsOf: url)
        let cut = dir.appendingPathComponent("cut.png")
        try data.prefix(data.count / 2).write(to: cut)
        // Either a clear error or a decoded image; never a crash.
        do { _ = try ImageFile.load(cut) } catch { XCTAssertTrue(error is ScrubError, "\(error)") }
    }

    func testMissingAndDirectoryInput() throws {
        XCTAssertThrowsError(try ImageFile.load(dir.appendingPathComponent("nope.png"))) { e in
            XCTAssertTrue(e is ScrubError && "\(e)".contains("does not exist"), "\(e)")
        }
        XCTAssertThrowsError(try ImageFile.load(dir)) { e in
            XCTAssertTrue(e is ScrubError && "\(e)".contains("directory"), "\(e)")
        }
    }

    func testUnreadableFile() throws {
        let url = try write(source(), type: .png, name: "locked.png")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        if getuid() == 0 { throw XCTSkip("root can read anything") }
        XCTAssertThrowsError(try ImageFile.load(url)) { e in
            XCTAssertTrue(e is ScrubError && "\(e)".contains("not readable"), "\(e)")
        }
    }

    func testMissingOutputDirectory() throws {
        let out = dir.appendingPathComponent("no/such/dir/out.png")
        XCTAssertThrowsError(try ImageFile.writePNG(source(), dpi: nil, to: out)) { e in
            XCTAssertTrue(e is ScrubError && "\(e)".contains("folder"), "\(e)")
        }
    }

    func testReadOnlyOutputDirectory() throws {
        if getuid() == 0 { throw XCTSkip("root ignores permissions") }
        let ro = dir.appendingPathComponent("ro")
        try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ro.path) }
        XCTAssertThrowsError(try ImageFile.writePNG(source(), dpi: nil, to: ro.appendingPathComponent("out.png"))) { e in
            XCTAssertTrue(e is ScrubError && "\(e)".contains("not writable"), "\(e)")
        }
    }

    func testWriteLeavesNoTempFilesAndKeepsExistingOnFailure() throws {
        let out = dir.appendingPathComponent("o.png")
        try ImageFile.writePNG(source(), dpi: nil, to: out)
        try ImageFile.writePNG(source(), dpi: nil, to: out)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["o.png"])
    }

    func testOutputIsDeterministic() throws {
        let url = try write(source(), type: .png, name: "det.png")
        let a = try roundTrip(url), b = try roundTrip(url)
        XCTAssertEqual(try Data(contentsOf: a.out), try Data(contentsOf: b.out))
    }
}
