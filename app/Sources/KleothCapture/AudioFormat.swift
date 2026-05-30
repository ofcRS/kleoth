import Foundation
import AVFoundation

/// Helpers for producing AAC encoder settings used when writing `.m4a` files.
public enum AudioFormat {
    /// AAC settings for a single-channel recording at the given sample rate.
    public static func aacSettings(sampleRate: Double = 48_000, channels: Int = 1) -> [String: Any] {
        fatalError("unimplemented")
    }
}
