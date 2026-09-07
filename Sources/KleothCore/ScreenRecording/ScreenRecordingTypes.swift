import Foundation

/// Shared value types for a screen-recording session (design §3.1). Property
/// names are acronym-free (`fileSizeBytes`, `displayId` style) — the project's
/// snake_case round-trip rule applies to anything that could ever be stored.
public enum ScreenRecordingStopReason: Equatable, Sendable {
    /// The user clicked the pill / the popover row / used the menu.
    case user
    /// The app is terminating; the writer gets `finalizeTimeout` to finish.
    case quit
    /// `SCStream` stopped itself (the "Stop Sharing" chip, display asleep, …).
    case systemStoppedStream
    case writerFailed
    /// The display being captured went away.
    case displayLost
}

/// Why a session never started, or ended without a usable file. Each maps to one
/// row of the error matrix (§7).
public enum ScreenRecordingFailure: Equatable, Sendable {
    case permissionNeeded
    /// Preflight says no although the user granted it — the classic
    /// "granted but the process was never relaunched" state.
    case permissionStale
    case noDisplay
    case diskFull
    case alreadyActive
    case outputUnwritable(String)
    case captureFailed(String)
    case writerFailed(String)
    /// Zero video frames were appended; the file is deleted.
    case nothingCaptured
}

/// What one finished session produced. Stored nowhere in v1 — it drives the
/// pill's `.saved` text and the popover row.
public struct ScreenRecordingSummary: Equatable, Sendable {
    /// A stretch where the microphone produced no real samples (device switch,
    /// permission revoked mid-session). `at` is relative to the session start.
    public struct MicGap: Equatable, Sendable {
        public var at: TimeInterval
        public var duration: TimeInterval

        public init(at: TimeInterval, duration: TimeInterval) {
            self.at = at
            self.duration = duration
        }
    }

    /// The FINAL url (the `.recording` suffix has already been stripped).
    public var url: URL
    public var duration: TimeInterval
    public var fileSizeBytes: Int64
    public var videoFramesAppended: Int
    public var droppedFrames: Int
    public var micCaptured: Bool
    public var micGaps: [MicGap]
    public var stopReason: ScreenRecordingStopReason

    public init(
        url: URL,
        duration: TimeInterval,
        fileSizeBytes: Int64,
        videoFramesAppended: Int,
        droppedFrames: Int,
        micCaptured: Bool,
        micGaps: [MicGap],
        stopReason: ScreenRecordingStopReason
    ) {
        self.url = url
        self.duration = duration
        self.fileSizeBytes = fileSizeBytes
        self.videoFramesAppended = videoFramesAppended
        self.droppedFrames = droppedFrames
        self.micCaptured = micCaptured
        self.micGaps = micGaps
        self.stopReason = stopReason
    }

    /// "48 MB" / "1.2 GB".
    public var sizeText: String {
        ScreenRecordingFileNaming.sizeText(bytes: fileSizeBytes)
    }

    /// The pill's `.saved` line: "2:14 · 48 MB".
    public var pillText: String {
        "\(ElapsedFormatter.string(seconds: Int(duration))) · \(sizeText)"
    }
}
