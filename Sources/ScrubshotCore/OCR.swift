import CoreGraphics
import Foundation
import Vision

/// One Vision text observation, mapped to pixel coordinates of the original image
/// (top-left origin) no matter what scale OCR ran at.
public final class OCRPiece {
    public let text: String
    public let box: CGRect
    public let confidence: Float
    private let candidate: VNRecognizedText
    private let imageSize: CGSize

    init(candidate: VNRecognizedText, observationBox: CGRect, imageSize: CGSize) {
        self.candidate = candidate
        self.text = candidate.string
        self.confidence = candidate.confidence
        self.imageSize = imageSize
        self.box = OCRPiece.toPixels(observationBox, imageSize)
    }

    static func toPixels(_ n: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: n.minX * size.width, y: (1 - n.maxY) * size.height,
               width: n.width * size.width, height: n.height * size.height)
    }

    /// Box for a UTF-16 range of `text`. Vision answers at word granularity, so a range
    /// inside a word returns the whole word's box. Falls back to a proportional slice.
    public func box(for range: NSRange) -> CGRect {
        let ns = text as NSString
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
        if clamped.length > 0, let r = Range(clamped, in: text),
           let obs = try? candidate.boundingBox(for: r) {
            let b = OCRPiece.toPixels(obs.boundingBox, imageSize)
            if b.width > 0, b.height > 0 { return b }
        }
        let n = max(1, ns.length)
        let x0 = box.minX + box.width * CGFloat(clamped.location) / CGFloat(n)
        let w = box.width * CGFloat(clamped.length) / CGFloat(n)
        return CGRect(x: x0, y: box.minY, width: max(1, w), height: box.height)
    }
}

/// Observations Vision returned on one visual line, joined with single spaces.
public struct OCRLine {
    public struct Part {
        public let piece: OCRPiece
        /// UTF-16 offset of `piece.text` inside `OCRLine.text`.
        public let offset: Int
    }

    public let text: String
    public let parts: [Part]
    public let box: CGRect
}

public enum OCR {
    /// Runs Vision text recognition. `scale` > 1 upsamples first, which helps small text.
    public static func recognize(_ image: CGImage, scale: Double = 1) throws -> [OCRPiece] {
        let size = CGSize(width: image.width, height: image.height)
        let input = scale == 1 ? image : try upscale(image, scale)
        // Vision rejects images of 2 pixels or less in a dimension; none of those can hold text.
        if input.width <= 2 || input.height <= 2 { return [] }
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0
        let handler = VNImageRequestHandler(cgImage: input, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ScrubError.ocr(error.localizedDescription)
        }
        var pieces: [OCRPiece] = []
        for obs in request.results ?? [] {
            guard let c = obs.topCandidates(1).first, !c.string.isEmpty else { continue }
            pieces.append(OCRPiece(candidate: c, observationBox: obs.boundingBox, imageSize: size))
        }
        return pieces
    }

    static func upscale(_ image: CGImage, _ scale: Double) throws -> CGImage {
        let w = Int((Double(image.width) * scale).rounded()), h = Int((Double(image.height) * scale).rounded())
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ScrubError.ocr("could not upscale")
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw ScrubError.ocr("could not upscale") }
        return out
    }

    /// Groups observations into visual lines so a term split across two observations
    /// still matches.
    public static func lines(_ pieces: [OCRPiece]) -> [OCRLine] {
        let sorted = pieces.sorted { a, b in
            a.box.minX != b.box.minX ? a.box.minX < b.box.minX : a.box.minY < b.box.minY
        }
        var groups: [[OCRPiece]] = []
        for p in sorted {
            var placed = false
            for i in groups.indices {
                let last = groups[i].last!
                let h = min(last.box.height, p.box.height)
                let sameRow = abs(last.box.midY - p.box.midY) < 0.5 * h
                    && abs(last.box.height - p.box.height) < 0.6 * max(last.box.height, p.box.height)
                let gap = p.box.minX - last.box.maxX
                if sameRow && gap > -0.3 * h && gap < 3 * h {
                    groups[i].append(p)
                    placed = true
                    break
                }
            }
            if !placed { groups.append([p]) }
        }
        var lines: [OCRLine] = []
        for g in groups {
            var text = ""
            var parts: [OCRLine.Part] = []
            var box = g[0].box
            for p in g {
                if !text.isEmpty { text += " " }
                parts.append(.init(piece: p, offset: (text as NSString).length))
                text += p.text
                box = box.union(p.box)
            }
            lines.append(OCRLine(text: text, parts: parts, box: box))
        }
        return lines.sorted { a, b in
            a.box.minY != b.box.minY ? a.box.minY < b.box.minY : a.box.minX < b.box.minX
        }
    }
}
