import Foundation
import ScreenCaptureKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Errors thrown while capturing a screenshot.
public enum ScreenshotCaptureError: Error, Sendable {
    case noDisplayAvailable
    case pngEncodingFailed
}

/// Captures a single screen frame via `SCScreenshotManager` and writes it as a
/// PNG file.
public enum ScreenshotCapture {
    /// Captures one screenshot of the main display and writes it to `outputURL`
    /// as a PNG, returning the URL.
    ///
    /// - Note: requires signed bundle + TCC grant (Screen Recording permission)
    ///   at runtime; compiles without it but `SCShareableContent.current` will
    ///   fail when the permission is denied.
    @available(macOS 14.0, *)
    @discardableResult
    public static func capture(to outputURL: URL) async throws -> URL {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw ScreenshotCaptureError.noDisplayAvailable
        }

        // Capture the whole display, excluding no windows.
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        // Capture at native resolution; no scaling.
        configuration.scalesToFit = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        try writePNG(image, to: outputURL)
        return outputURL
    }

    /// Encodes a `CGImage` as PNG and writes it to `url`.
    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenshotCaptureError.pngEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotCaptureError.pngEncodingFailed
        }
    }
}
