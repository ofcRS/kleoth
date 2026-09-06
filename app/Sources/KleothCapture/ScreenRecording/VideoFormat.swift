import AVFoundation
import CoreGraphics
import Foundation
import KleothCore
import VideoToolbox

/// H.264 output settings for the movie writer's video input — the video half of
/// what `AudioFormat.aacSettings` is for audio (AudioFormat.swift:33-48).
///
/// Every number is justified in design §5.4. The short version: H.264 High with
/// an automatic level (Slack, Telegram, iMessage and every browser play it),
/// an area-scaled average bit rate that lands at 3 Mbps for 1080p — screen
/// content is low-motion, so the low end of the 3–6 Mbps guidance is enough —
/// a hard peak of twice that, a key frame every 2 s so scrubbing works, and no
/// frame reordering because this is a real-time encode.
public enum VideoFormat {
    /// - Parameters:
    ///   - pixelSize: the (even) output size from `CaptureGeometry.outputPixelSize`.
    ///   - averageBitRate: bits/second from `CaptureGeometry.videoBitRate(pixelSize:)`.
    public static func h264Settings(pixelSize: CGSize, averageBitRate: Int) -> [String: Any] {
        let width = max(2, Int(pixelSize.width.rounded(.down)))
        let height = max(2, Int(pixelSize.height.rounded(.down)))
        let average = max(ScreenRecordingDefaults.minimumVideoBitRate, averageBitRate)

        // `kVTCompressionPropertyKey_DataRateLimits` is [bytes, seconds] pairs,
        // not bits: a one-second window holding at most 2× the average
        // (the HLS peak rule). VideoToolbox keys may be mixed into
        // `AVVideoCompressionPropertiesKey` (AVVideoSettings.h:188).
        let peakBytesPerSecond = Double(average) * ScreenRecordingDefaults.peakBitRateMultiplier / 8
        let dataRateLimits: [NSNumber] = [
            NSNumber(value: peakBytesPerSecond.rounded()),
            NSNumber(value: 1.0),
        ]

        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: average,
            kVTCompressionPropertyKey_DataRateLimits as String: dataRateLimits,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            // Required with an AutoLevel profile (AVVideoSettings.h:245-247).
            AVVideoExpectedSourceFrameRateKey: Int(ScreenRecordingDefaults.framesPerSecond),
            AVVideoMaxKeyFrameIntervalDurationKey: ScreenRecordingDefaults.keyFrameIntervalSeconds,
            // "may yield the best results" for real-time encoding
            // (AVVideoSettings.h:206-210) and keeps PTS == DTS.
            AVVideoAllowFrameReorderingKey: false,
        ]

        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
            // Hardware encode is VideoToolbox's default on this hardware
            // (VTCompressionProperties.h:788); asking explicitly documents the
            // intent. `Require…` is deliberately NOT set — a software fallback
            // beats a failed recording.
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
            ],
        ]
    }
}
