import CoreGraphics
import Foundation

/// One pixel, 8 bits per channel, in the bitmap's own color space.
public struct Pixel: Equatable, Hashable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// Largest per-channel difference. Cheap and good enough for UI colors.
    public func distance(to o: Pixel) -> Int {
        max(abs(Int(r) - Int(o.r)), abs(Int(g) - Int(o.g)), abs(Int(b) - Int(o.b)), abs(Int(a) - Int(o.a)))
    }

    /// Rec. 601 luma, 0...255.
    public var luma: Double { 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b) }
}

/// A mutable RGBA8 (premultiplied last) pixel buffer that keeps the source color space,
/// so pixels we do not touch come back out exactly as they went in.
public final class Bitmap {
    public let width: Int
    public let height: Int
    public let colorSpace: CGColorSpace
    public var data: [UInt8]

    public init(width: Int, height: Int, colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) {
        self.width = width
        self.height = height
        self.colorSpace = colorSpace
        self.data = [UInt8](repeating: 0, count: width * height * 4)
    }

    public convenience init(image: CGImage) throws {
        let space: CGColorSpace
        if let s = image.colorSpace, s.model == .rgb {
            space = s
        } else {
            space = CGColorSpace(name: CGColorSpace.sRGB)!
        }
        guard image.width > 0, image.height > 0, image.width * image.height <= ImageFile.maxPixels else {
            throw ScrubError.imageDecode("image is \(image.width)x\(image.height), over the \(ImageFile.maxPixels / 1_000_000) megapixels limit")
        }
        self.init(width: image.width, height: image.height, colorSpace: space)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .none
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !ok { throw ScrubError.imageDecode("could not create a bitmap context") }
    }

    public func copy() -> Bitmap {
        let b = Bitmap(width: width, height: height, colorSpace: colorSpace)
        b.data = data
        return b
    }

    @inline(__always) public func contains(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    @inline(__always) public subscript(x: Int, y: Int) -> Pixel {
        get {
            let i = (y * width + x) * 4
            return Pixel(r: data[i], g: data[i + 1], b: data[i + 2], a: data[i + 3])
        }
        set {
            let i = (y * width + x) * 4
            data[i] = newValue.r; data[i + 1] = newValue.g; data[i + 2] = newValue.b; data[i + 3] = newValue.a
        }
    }

    public func makeImage() throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(data) as CFData), let img = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ) else { throw ScrubError.imageEncode("could not build an image from the bitmap") }
        return img
    }

    /// Pixel rectangle clamped to the bitmap.
    public func clamp(_ r: PixelRect) -> PixelRect {
        let x0 = max(0, r.x0), y0 = max(0, r.y0)
        let x1 = min(width, r.x1), y1 = min(height, r.y1)
        return PixelRect(x0: x0, y0: y0, x1: max(x0, x1), y1: max(y0, y1))
    }
}

/// Integer pixel rectangle, top-left origin, half-open: [x0, x1) x [y0, y1).
public struct PixelRect: Equatable, Codable, CustomStringConvertible {
    public var x0: Int, y0: Int, x1: Int, y1: Int

    public init(x0: Int, y0: Int, x1: Int, y1: Int) {
        self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1
    }

    public init(_ r: CGRect) {
        self.init(x0: Int(r.minX.rounded(.down)), y0: Int(r.minY.rounded(.down)),
                  x1: Int(r.maxX.rounded(.up)), y1: Int(r.maxY.rounded(.up)))
    }

    public var width: Int { x1 - x0 }
    public var height: Int { y1 - y0 }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var cgRect: CGRect { CGRect(x: x0, y: y0, width: width, height: height) }

    public func contains(_ x: Int, _ y: Int) -> Bool { x >= x0 && x < x1 && y >= y0 && y < y1 }

    public func union(_ o: PixelRect) -> PixelRect {
        PixelRect(x0: min(x0, o.x0), y0: min(y0, o.y0), x1: max(x1, o.x1), y1: max(y1, o.y1))
    }

    public func intersects(_ o: PixelRect) -> Bool {
        x0 < o.x1 && o.x0 < x1 && y0 < o.y1 && o.y0 < y1
    }

    public var description: String { "(\(x0),\(y0) \(width)x\(height))" }

    enum CodingKeys: String, CodingKey { case x, y, width, height }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(x0, forKey: .x); try c.encode(y0, forKey: .y)
        try c.encode(width, forKey: .width); try c.encode(height, forKey: .height)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let x = try c.decode(Int.self, forKey: .x), y = try c.decode(Int.self, forKey: .y)
        let w = try c.decode(Int.self, forKey: .width), h = try c.decode(Int.self, forKey: .height)
        self.init(x0: x, y0: y, x1: x + w, y1: y + h)
    }
}

public enum ScrubError: Error, CustomStringConvertible {
    case imageDecode(String)
    case imageEncode(String)
    case rules(String)
    case usage(String)
    case ocr(String)

    public var description: String {
        switch self {
        case .imageDecode(let s): return "could not read image: \(s)"
        case .imageEncode(let s): return "could not write image: \(s)"
        case .rules(let s): return "rules: \(s)"
        case .usage(let s): return s
        case .ocr(let s): return "OCR failed: \(s)"
        }
    }
}
