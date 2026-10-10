import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KleothCore

/// Whatever an image engine returns becomes one `cover.jpg` (design doc
/// 2026-09-24 §3.4, §10 landscape addendum): a centre-cropped 16:9 picture at
/// most 1536 px wide, JPEG 0.85, with no EXIF/GPS/IPTC/TIFF metadata.
@Suite struct CoverImageFileTests {
    private static let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    private static let green = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
    private static let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)

    /// The output is a JPEG exactly `width`×`height`.
    private func expectJPEG(
        _ data: Data, width: Int, height: Int, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        #expect(CoverTestImages.imageType(of: data) == "public.jpeg", sourceLocation: sourceLocation)
        let size = try #require(CoverImageFile.pixelSize(of: data), sourceLocation: sourceLocation)
        #expect(size.width == width, sourceLocation: sourceLocation)
        #expect(size.height == height, sourceLocation: sourceLocation)
    }

    /// A JPEG re-encoding of `png` that carries every metadata dictionary a
    /// camera or an image service might add: EXIF, GPS, IPTC and TIFF.
    private func jpegWithMetadata(from png: Data) throws -> Data {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let output = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        )
        let metadata: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "board meeting"],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 55.75, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 37.62, kCGImagePropertyGPSLongitudeRef: "E",
            ],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "a caption"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Test Camera"],
        ]
        CGImageDestinationAddImageFromSource(destination, source, 0, metadata as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test func largeWidePNGBecomesA1536By864JPEG() throws {
        let normalized = try CoverImageFile.normalize(CoverTestImages.png(width: 2048, height: 1152))

        try expectJPEG(normalized, width: 1536, height: 864)
        #expect(normalized.count < 600_000)
    }

    /// What OpenRouter (`aspect_ratio: 16:9`) and a Flux server answer with.
    @Test func openRouterSizeIsCroppedToExactly16By9() throws {
        let normalized = try CoverImageFile.normalize(CoverTestImages.png(width: 1344, height: 768))

        try expectJPEG(normalized, width: 1344, height: 756)
    }

    /// What Codex `image_gen` answers with: 3:2, so rows come off top and bottom.
    @Test func threeByTwoImageLosesRowsNotColumns() throws {
        let normalized = try CoverImageFile.normalize(CoverTestImages.png(width: 1536, height: 1024))

        try expectJPEG(normalized, width: 1536, height: 864)
    }

    @Test func extraWideImageIsCentreCropped() throws {
        let wide = CoverTestImages.png(width: 3072, height: 864, bands: [Self.red, Self.green, Self.blue])

        let normalized = try CoverImageFile.normalize(wide)

        try expectJPEG(normalized, width: 1536, height: 864)
        // The crop keeps source columns 768…2304: the last quarter of red, all of
        // green, the first quarter of blue.
        let left = try #require(CoverTestImages.pixel(in: normalized, x: 8, y: 432))
        let middle = try #require(CoverTestImages.pixel(in: normalized, x: 768, y: 432))
        let right = try #require(CoverTestImages.pixel(in: normalized, x: 1528, y: 432))
        #expect(left.r > 180 && left.g < 90 && left.b < 90)
        #expect(middle.g > 180 && middle.r < 90 && middle.b < 90)
        #expect(right.b > 180 && right.r < 90 && right.g < 90)
    }

    /// An engine that ignores the size and answers square keeps its full width.
    @Test func squareImageKeepsItsWidth() throws {
        let square = CoverTestImages.png(width: 1024, height: 1024, bands: [Self.red, Self.green, Self.blue])

        let normalized = try CoverImageFile.normalize(square)

        try expectJPEG(normalized, width: 1024, height: 576)
        let left = try #require(CoverTestImages.pixel(in: normalized, x: 8, y: 288))
        #expect(left.r > 180 && left.g < 90 && left.b < 90)
    }

    @Test func smallImageIsNotUpscaled() throws {
        let normalized = try CoverImageFile.normalize(CoverTestImages.png(width: 640, height: 360))

        try expectJPEG(normalized, width: 640, height: 360)
    }

    @Test func garbageThrowsUnreadableImage() {
        #expect(throws: CoverError.unreadableImage) {
            try CoverImageFile.normalize(Data("not an image".utf8))
        }
        #expect(CoverImageFile.pixelSize(of: Data("not an image".utf8)) == nil)
    }

    @Test func outputCarriesNoMetadata() throws {
        let tagged = try jpegWithMetadata(from: CoverTestImages.png(width: 1254, height: 1254))
        let input = CoverTestImages.properties(of: tagged)
        // The input really carries the metadata the output must drop.
        let inputExif = try #require(input[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(inputExif[kCGImagePropertyExifUserComment] != nil)
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary] {
            #expect(input[key] != nil, "input lacks \(key)")
        }

        let output = CoverTestImages.properties(of: try CoverImageFile.normalize(tagged))

        #expect(!output.isEmpty)
        // ImageIO always writes a bare {Exif} of its own and nothing removes it
        // (see CoverImageFile.normalize): allow exactly its three keys. If a new
        // harmless key appears in that bare {Exif} (an OS update), add it to
        // this list — after checking it isn't taken from the source image.
        if let rawExif = output[kCGImagePropertyExifDictionary] {
            let exif = try #require(rawExif as? [CFString: Any])
            let ownExifKeys: Set<CFString> = [
                kCGImagePropertyExifColorSpace, kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension,
            ]
            #expect(Set(exif.keys).isSubset(of: ownExifKeys), "unexpected Exif keys: \(exif.keys)")
        }
        #expect(output[kCGImagePropertyGPSDictionary] == nil)
        #expect(output[kCGImagePropertyIPTCDictionary] == nil)
        #expect(output[kCGImagePropertyTIFFDictionary] == nil)
    }

    @Test func webpInputIsAccepted() throws {
        #expect(CoverTestImages.imageType(of: CoverTestImages.webp16) == "org.webmproject.webp")

        let normalized = try CoverImageFile.normalize(CoverTestImages.webp16)

        try expectJPEG(normalized, width: 16, height: 9)
        let pixel = try #require(CoverTestImages.pixel(in: normalized, x: 8, y: 4))
        #expect(pixel.g > 120 && pixel.r < 90 && pixel.b < 130, "pixel \(pixel)")
    }

    @Test func jpegInputIsAccepted() throws {
        let jpeg = try CoverImageFile.normalize(CoverTestImages.png(width: 2048, height: 1152))
        #expect(CoverTestImages.imageType(of: jpeg) == "public.jpeg")

        let normalized = try CoverImageFile.normalize(jpeg)

        try expectJPEG(normalized, width: 1536, height: 864)
    }
}
