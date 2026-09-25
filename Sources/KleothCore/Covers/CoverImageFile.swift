import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns whatever an image engine returns into the one file History shows
/// (design doc 2026-09-24 §3.4). Engines answer with PNG, JPEG or WebP at
/// 1024–1254 px, and not always square; `cover.jpg` is always a square of at
/// most 1024 px at JPEG 0.85 (about 150–300 KB) with none of the source's
/// metadata (no EXIF, GPS, IPTC or TIFF), so every
/// cover looks and weighs the same whichever engine drew it.
///
/// ImageIO and Core Graphics only (both on macOS 13), no AppKit: the CLI
/// normalizes too.
public enum CoverImageFile {
    /// The longest side kept. Smaller pictures are never upscaled.
    public static let maxPixelSize = 1024
    public static let jpegQuality = 0.85

    /// PNG/JPEG/WebP → centre-cropped square, ≤ 1024 px, JPEG 0.85, no metadata (ImageIO).
    ///
    /// The picture is redrawn into a fresh sRGB bitmap rather than re-encoded
    /// from the source, so nothing of the source's EXIF/GPS/IPTC/TIFF can ride
    /// along; the only metadata left is ImageIO's own bare `{Exif}` (colour
    /// space and pixel dimensions). Throws `CoverError.unreadableImage` for
    /// bytes ImageIO can't decode, and for an output whose header doesn't read
    /// back as the target square.
    ///
    /// EXIF orientation is not applied: no engine emits it, and a user's own
    /// `cover.png` bypasses `normalize`.
    public static func normalize(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CoverError.unreadableImage }
        let side = min(image.width, image.height)
        guard side > 0 else { throw CoverError.unreadableImage }
        let crop = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        guard let square = image.cropping(to: crop) else { throw CoverError.unreadableImage }
        let target = min(side, maxPixelSize)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: target, height: target, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CoverError.unreadableImage }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1))        // a transparent PNG flattens onto white — JPEG has no alpha
        context.fill(CGRect(x: 0, y: 0, width: target, height: target))
        context.draw(square, in: CGRect(x: 0, y: 0, width: target, height: target))
        guard let scaled = context.makeImage() else { throw CoverError.unreadableImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw CoverError.unreadableImage }
        // A CGImage rendered here carries none of the source's EXIF/GPS/IPTC/TIFF.
        // ImageIO still writes a bare {Exif} of its own (ColorSpace and the pixel
        // dimensions, nothing personal), and nothing passed here removes it. Never
        // pass kCFNull for {Exif} or {TIFF} to try: on macOS 26 ImageIO then writes
        // a truncated 20-byte file and CGImageDestinationFinalize still returns true.
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: jpegQuality]
        CGImageDestinationAddImage(destination, scaled, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CoverError.unreadableImage }
        // Finalize's true is not proof of a good file (see above), so read the
        // header back: a broken JPEG must fail here, not become cover.jpg.
        guard let written = pixelSize(of: output as Data), written.width == target, written.height == target
        else { throw CoverError.unreadableImage }
        return output as Data
    }

    /// The first image's pixel size as ImageIO reports it, without decoding
    /// the pixels; nil for bytes ImageIO can't read. Used by `normalize`'s
    /// read-back, tests and the CLI's output line.
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}
