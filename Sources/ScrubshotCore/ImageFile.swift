import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image file reading and writing. Output is always PNG, with no metadata except
/// the color profile (kept so colors do not shift) and DPI (kept so Retina
/// screenshots still display at their point size).
public enum ImageFile {
    public struct Loaded {
        public let image: CGImage
        public let dpi: (Double, Double)?
    }

    /// Largest image we accept, in pixels. The working buffer is 4 bytes per pixel and
    /// the pipeline keeps a few copies, so 100 MP is roughly 1.5 GB of memory.
    public static let maxPixels = 100_000_000

    /// True when width x height is positive and within `maxPixels`, without overflowing.
    public static func pixelCountAllowed(_ w: Int, _ h: Int) -> Bool {
        guard w > 0, h > 0 else { return false }
        let (n, overflow) = w.multipliedReportingOverflow(by: h)
        return !overflow && n <= maxPixels
    }

    /// Reads the first (and only) frame. EXIF orientation is applied to the pixels, so
    /// the output, which carries no EXIF, looks the same as the input did.
    /// Multi-frame files (animated GIF, multi-page TIFF) are refused, not truncated.
    public static func load(_ url: URL) throws -> Loaded {
        let path = url.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            throw ScrubError.imageDecode("\(path) does not exist")
        }
        if isDir.boolValue { throw ScrubError.imageDecode("\(path) is a directory, not an image file") }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw ScrubError.imageDecode("\(path) is not readable (check file permissions)")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
        if size == 0 { throw ScrubError.imageDecode("\(path) is empty") }

        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ScrubError.imageDecode("\(path) is not a supported image (PNG, JPEG, HEIC, TIFF, GIF, ...)")
        }
        return try decode(src, path: path)
    }

    /// Same as `load(_:)`, for bytes the caller already read (for example through a descriptor
    /// opened without following symlinks). `name` is only used in error messages.
    public static func load(data: Data, name: String) throws -> Loaded {
        if data.isEmpty { throw ScrubError.imageDecode("\(name) is empty") }
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ScrubError.imageDecode("\(name) is not a supported image (PNG, JPEG, HEIC, TIFF, GIF, ...)")
        }
        return try decode(src, path: name)
    }

    private static func decode(_ src: CGImageSource, path: String) throws -> Loaded {
        guard CGImageSourceGetStatus(src) == .statusComplete || CGImageSourceGetStatus(src) == .statusIncomplete,
              CGImageSourceGetCount(src) >= 1 else {
            throw ScrubError.imageDecode("\(path) has no readable image")
        }
        let frames = CGImageSourceGetCount(src)
        if frames > 1 {
            throw ScrubError.imageDecode("\(path) has \(frames) frames (animated or multi-page); only single-image files are supported")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        if let w = props?[kCGImagePropertyPixelWidth] as? Int, let h = props?[kCGImagePropertyPixelHeight] as? Int,
           w > 0, h > 0, !pixelCountAllowed(w, h) {
            throw ScrubError.imageDecode("\(path) is \(w)x\(h), over the \(maxPixels / 1_000_000) megapixels limit")
        }
        guard let decoded = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ScrubError.imageDecode("\(path) could not be decoded (damaged or unsupported)")
        }
        if !pixelCountAllowed(decoded.width, decoded.height) {
            throw ScrubError.imageDecode("\(path) is \(decoded.width)x\(decoded.height), over the \(maxPixels / 1_000_000) megapixels limit")
        }
        var dpi: (Double, Double)?
        if let dx = props?[kCGImagePropertyDPIWidth] as? Double, let dy = props?[kCGImagePropertyDPIHeight] as? Double {
            dpi = (dx, dy)
        }
        var image = decoded
        let orientation = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        if (2...8).contains(orientation) {
            image = try Bitmap(image: decoded).oriented(orientation).makeImage()
            if orientation >= 5, let d = dpi { dpi = (d.1, d.0) }
        }
        return Loaded(image: image, dpi: dpi)
    }

    public static func pngData(_ image: CGImage, dpi: (Double, Double)?) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw ScrubError.imageEncode("PNG encoder unavailable")
        }
        var props: [CFString: Any] = [:]
        if let dpi {
            props[kCGImagePropertyDPIWidth] = dpi.0
            props[kCGImagePropertyDPIHeight] = dpi.1
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ScrubError.imageEncode("PNG encode failed") }
        return try stripChunks(out as Data)
    }

    /// PNG chunks that may stay: image data, color, transparency and DPI. Everything
    /// else (eXIf, iTXt, tEXt, zTXt, tIME, ...) is dropped.
    static let keptChunks: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "tRNS", "iCCP", "sRGB", "gAMA", "cHRM", "pHYs", "sBIT"]

    public static func stripChunks(_ png: Data) throws -> Data {
        let bytes = [UInt8](png)
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count > 8, Array(bytes[0..<8]) == signature else { throw ScrubError.imageEncode("not a PNG") }
        var out = Data(signature)
        var i = 8
        while i + 12 <= bytes.count {
            let len = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            let end = i + 12 + len
            guard len >= 0, end <= bytes.count else { throw ScrubError.imageEncode("corrupt PNG chunk") }
            let type = String(decoding: bytes[(i + 4)..<(i + 8)], as: UTF8.self)
            if keptChunks.contains(type) { out.append(contentsOf: bytes[i..<end]) }
            i = end
        }
        return out
    }

    /// Names of the chunks in a PNG, in order.
    public static func chunkTypes(_ png: Data) -> [String] {
        let bytes = [UInt8](png)
        var types: [String] = []
        var i = 8
        while i + 12 <= bytes.count {
            let len = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            types.append(String(decoding: bytes[(i + 4)..<(i + 8)], as: UTF8.self))
            i += 12 + len
        }
        return types
    }

    public static func writePNG(_ image: CGImage, dpi: (Double, Double)?, to url: URL) throws {
        let data = try pngData(image, dpi: dpi)
        let dir = url.deletingLastPathComponent().path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            throw ScrubError.imageEncode("output folder does not exist: \(dir)")
        }
        guard FileManager.default.isWritableFile(atPath: dir) else {
            throw ScrubError.imageEncode("output folder is not writable: \(dir)")
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ScrubError.imageEncode("could not save \(url.path): \((error as NSError).localizedDescription)")
        }
    }
}
