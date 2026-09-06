import CoreGraphics
import Foundation

/// H.264 output settings for the movie writer's video input — the video half of
/// what `AudioFormat.aacSettings` is for audio (AudioFormat.swift:33-48).
///
/// **T0 STUB** — the signature is final, the dictionary is T3's (design §5.4:
/// `AVVideoCodecKey`, the pixel size, `averageBitRate`, a peak of
/// `peakBitRateMultiplier` × average, a `keyFrameIntervalSeconds` key-frame
/// interval, and the profile level).
public enum VideoFormat {
    public static func h264Settings(pixelSize: CGSize, averageBitRate: Int) -> [String: Any] {
        _ = pixelSize
        _ = averageBitRate
        return [:]
    }
}
