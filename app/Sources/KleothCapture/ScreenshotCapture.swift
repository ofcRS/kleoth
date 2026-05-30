import Foundation
import ScreenCaptureKit

/// Captures a single screen frame via `SCScreenshotManager`.
public enum ScreenshotCapture {
    /// Captures one screenshot and writes it to `outputURL`, returning it.
    @available(macOS 14.0, *)
    public static func capture(to outputURL: URL) async throws -> URL {
        fatalError("unimplemented")
    }
}
