import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encoded test pictures and ways to look inside them, shared by the cover
/// suites (image normalization, the image clients, the drawing). Built with
/// Core Graphics and ImageIO only, so no fixture files are needed.
enum CoverTestImages {
    /// A 16×16 solid green (51, 153, 102) lossless WebP (`VP8L`, 38 bytes). ImageIO
    /// reads WebP but cannot write it, so this was made once with Pillow
    /// (`Image.new("RGB", (16, 16), (51, 153, 102)).save(…, "WEBP", lossless=True)`).
    static let webp16 = Data(base64Encoded: "UklGRh4AAABXRUJQVlA4TBEAAAAvD8ADAAfQzM7UrP+BiOh/AAA=")!

    /// A PNG `width`×`height`; `bands` paints vertical thirds left→right (default: one solid colour).
    /// Any number of bands works: each gets an equal-width column, in order.
    static func png(
        width: Int,
        height: Int,
        bands: [CGColor] = [CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1)]
    ) -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { preconditionFailure("CoverTestImages: no \(width)×\(height) RGBA context") }
        for (index, color) in bands.enumerated() {
            let left = width * index / bands.count
            let right = width * (index + 1) / bands.count
            context.setFillColor(color)
            context.fill(CGRect(x: left, y: 0, width: right - left, height: height))
        }
        let output = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(
                  output as CFMutableData, UTType.png.identifier as CFString, 1, nil
              )
        else { preconditionFailure("CoverTestImages: could not set up the PNG encoder") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { preconditionFailure("CoverTestImages: PNG encode failed") }
        return output as Data
    }

    /// RGB of one pixel of an encoded image (top-left origin).
    static func pixel(in data: Data, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              (0..<image.width).contains(x), (0..<image.height).contains(y),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let bytesPerRow = image.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        // A bitmap context's first row in memory is the image's top row.
        let offset = y * bytesPerRow + x * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }

    /// `CGImageSourceGetType` → "public.jpeg" / "public.png"; nil when ImageIO can't read the bytes.
    static func imageType(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceGetType(source) as String?
    }

    /// The first image's ImageIO properties (`{Exif}`, `{GPS}`, `{TIFF}`, …); empty when unreadable.
    static func properties(of data: Data) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }
}
