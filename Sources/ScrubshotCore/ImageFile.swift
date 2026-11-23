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

    public static func load(_ url: URL) throws -> Loaded {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ScrubError.imageDecode(url.path)
        }
        guard CGImageSourceGetCount(src) >= 1,
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ScrubError.imageDecode("\(url.path) has no image")
        }
        var dpi: (Double, Double)?
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let dx = props[kCGImagePropertyDPIWidth] as? Double,
           let dy = props[kCGImagePropertyDPIHeight] as? Double {
            dpi = (dx, dy)
        }
        return Loaded(image: img, dpi: dpi)
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
        try data.write(to: url, options: .atomic)
    }
}
