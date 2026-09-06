import Foundation

/// Single source of truth for every screen-recording constant (design
/// `.scratch/video-recording-thread/DESIGN.md` §3.1). Nothing else may redefine
/// these numbers — the same rule `DictationDefaults` lives by.
public enum ScreenRecordingDefaults {
    /// Folder under the output directory (`~/Kleoth/` by default).
    public static let directoryName = "screen-recordings"
    public static let filePrefix = "screen"
    /// In-flight name. A file still carrying this suffix at launch was
    /// interrupted (crash / force quit) and is swept by `startIfNeeded()`.
    public static let recordingSuffix = ".recording.mp4"
    public static let recoveredSuffix = "-recovered.mp4"
    /// `SCStreamConfiguration.minimumFrameInterval` numerator (SCStream.h:222).
    public static let framesPerSecond: Int32 = 30
    /// Loom's ladder / CleanShot's downscale precedent, and it dodges the
    /// 4096×2304 AVAssetWriter H.264 ceiling on a 5K display.
    public static let maxLongEdgePixels = 1920
    /// §5.4 (graft 1): the average bit rate at exactly 1920×1080.
    public static let videoBitRateAt1080p = 3_000_000
    public static let minimumVideoBitRate = 1_000_000
    /// HLS rule of thumb: peak ≤ 200 % of average.
    public static let peakBitRateMultiplier = 2.0
    public static let keyFrameIntervalSeconds = 2
    /// SCStream.h:300 default — matching it avoids a resample on the system side.
    public static let audioSampleRate = 48_000.0
    public static let audioChannels: UInt32 = 2
    /// Clamped by `AudioFormat.maxAACBitRate` before it reaches the encoder.
    public static let audioBitRate = 128_000
    /// 20 ms @ 48 kHz — one mix block.
    public static let mixBlockFrames = 960
    /// How far behind "now" the pump reads, so a late buffer still lands.
    public static let mixLatency: TimeInterval = 0.25
    public static let ringSeconds: TimeInterval = 2.0
    /// 2 ms: a write this close to the write cursor is appended contiguously
    /// (jitter must not become a click).
    public static let mixAlignToleranceFrames = 96
    /// §5.3 — OFF; the stop-time re-append covers a frozen screen (graft 10).
    public static let keepaliveInterval: TimeInterval? = nil
    /// nil disables the stale-grant detector.
    public static let firstFrameTimeout: TimeInterval? = 5.0
    public static let finalizeTimeout: TimeInterval = 5.0
    /// nil → a plain moov-at-front file (§5.5).
    public static let fragmentInterval: TimeInterval? = 10
    public static let minRegionPoints: CGFloat = 64
    public static let minFreeDiskBytes: Int64 = 500 * 1024 * 1024
    public static let savedConfirmation: TimeInterval = 4
    /// A `.saved` confirmation queued behind a live dictation phase is dropped
    /// once it is this stale.
    public static let savedConfirmationMaxDelay: TimeInterval = 10
    public static let micGapReportThreshold: TimeInterval = 0.5
    /// §4.5 clap-test knob: constant offset added to the mic's host time.
    public static let micOffsetCompensation: TimeInterval = 0
    /// Non-secret, rewritten rarely → `UserDefaults`, not the Keychain
    /// (`DictationPillController.placementDefaultsKey` precedent).
    public static let permissionRequestedDefaultsKey = "dev.kleoth.screenRecording.permissionRequestedAt"
}
