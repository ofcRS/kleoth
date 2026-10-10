import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns whatever an image engine returns into the one file History shows
/// (design doc 2026-09-24 §3.4). Engines answer with PNG, JPEG or WebP at
/// 1024–1536 px, and not always in the shape asked for; `cover.jpg` is always
/// 16:9, at most 1536 px wide, at JPEG 0.85 (about 200–450 KB) with none of the
/// source's metadata (no EXIF, GPS, IPTC or TIFF), so every cover looks and
/// weighs the same whichever engine drew it. Wide because the meeting page shows
/// it as a full-width band (§10 landscape addendum, 2026-09-28): a square cover
/// showed only its middle third there.
///
/// ImageIO and Core Graphics only (both on macOS 13), no AppKit: the CLI
/// normalizes too.
public enum CoverImageFile {
    /// Width : height of every `cover.jpg`.
    public static let aspectWidth = 16
    public static let aspectHeight = 9
    /// `aspectWidth / aspectHeight`, for views that size a thumbnail by its short side.
    public static let aspect = Double(aspectWidth) / Double(aspectHeight)
    /// The widest picture kept: Codex's 1536 px. Smaller pictures are never upscaled.
    public static let maxPixelWidth = 1536
    public static let jpegQuality = 0.85

    /// PNG/JPEG/WebP → the largest centred 16:9 crop, ≤ 1536 px wide, JPEG 0.85,
    /// no metadata (ImageIO). A wider source loses columns on both sides, a
    /// taller one (Codex's 3:2, or a square from an engine that ignored the
    /// size) rows off the top and bottom.
    ///
    /// The picture is redrawn into a fresh sRGB bitmap rather than re-encoded
    /// from the source, so nothing of the source's EXIF/GPS/IPTC/TIFF can ride
    /// along; the only metadata left is ImageIO's own bare `{Exif}` (colour
    /// space and pixel dimensions). Throws `CoverError.unreadableImage` for
    /// bytes ImageIO can't decode, and for an output whose header doesn't read
    /// back as the target size.
    ///
    /// EXIF orientation is not applied: no engine emits it, and a user's own
    /// `cover.png` bypasses `normalize`.
    public static func normalize(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CoverError.unreadableImage }
        // Integer maths: a source 16:9 up to rounding loses only those few rows
        // (OpenRouter's 1344×768 keeps 1344×756).
        let wider = image.width * aspectHeight >= image.height * aspectWidth
        let cropWidth = wider ? image.height * aspectWidth / aspectHeight : image.width
        let cropHeight = wider ? image.height : image.width * aspectHeight / aspectWidth
        guard cropWidth > 0, cropHeight > 0 else { throw CoverError.unreadableImage }
        let crop = CGRect(x: (image.width - cropWidth) / 2, y: (image.height - cropHeight) / 2,
                          width: cropWidth, height: cropHeight)
        guard let cropped = image.cropping(to: crop) else { throw CoverError.unreadableImage }
        let targetWidth = min(cropWidth, maxPixelWidth)
        let targetHeight = targetWidth == cropWidth ? cropHeight : targetWidth * aspectHeight / aspectWidth
        guard targetHeight > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: targetWidth, height: targetHeight, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CoverError.unreadableImage }
        let target = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1))        // a transparent PNG flattens onto white — JPEG has no alpha
        context.fill(target)
        context.draw(cropped, in: target)
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
        guard let written = pixelSize(of: output as Data), written.width == targetWidth, written.height == targetHeight
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
