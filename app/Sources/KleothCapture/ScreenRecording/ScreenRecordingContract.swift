import CoreGraphics
import Foundation
import KleothCore

/// The capture half of the screen-recording contract (design §3.2). Everything
/// here is a plain value that crosses the target seam; the machinery
/// (`SCStream`, the mic engine, the mix pump, the writer) is internal to
/// `ScreenRecorder`.
///
/// No `@available(macOS 14.4, *)` gate is needed: the package floor already is
/// 14.4 and this design uses no macOS 15 ScreenCaptureKit API (§5.1).
public struct ScreenRecordingTarget: Sendable, Equatable {
    public var displayID: CGDirectDisplayID
    /// Display-local, TOP-left-origin points (SCStream.h:269). `nil` = the whole
    /// display.
    public var sourceRect: CGRect?

    public init(displayID: CGDirectDisplayID, sourceRect: CGRect? = nil) {
        self.displayID = displayID
        self.sourceRect = sourceRect
    }
}

/// Everything one session needs, decided before it starts and never mutated.
public struct ScreenRecordingConfiguration: Sendable {
    public var target: ScreenRecordingTarget
    /// The in-flight `".recording.mp4"` URL
    /// (`ScreenRecordingFileNaming.recordingURL`); the recorder renames it on
    /// success.
    public var outputURL: URL
    /// False when the microphone is denied — system audio still records.
    public var captureMicrophone: Bool
    /// `nil` → a plain moov-at-front file (§5.5).
    public var fragmentInterval: TimeInterval?
    /// `nil` disables the stale-grant detector (§5.3).
    public var firstFrameTimeout: TimeInterval?

    public init(
        target: ScreenRecordingTarget,
        outputURL: URL,
        captureMicrophone: Bool,
        fragmentInterval: TimeInterval? = ScreenRecordingDefaults.fragmentInterval,
        firstFrameTimeout: TimeInterval? = ScreenRecordingDefaults.firstFrameTimeout
    ) {
        self.target = target
        self.outputURL = outputURL
        self.captureMicrophone = captureMicrophone
        self.fragmentInterval = fragmentInterval
        self.firstFrameTimeout = firstFrameTimeout
    }
}

/// What the recorder tells the controller while a session runs. Everything the
/// controller needs at the END of a session is in `ScreenRecordingSummary`
/// instead; these are the live, mid-session facts.
public enum ScreenRecorderEvent: Sendable {
    /// The first `.screen` sample of ANY status arrived — the stale-grant
    /// detector's all-clear.
    case firstFrame(hostTime: UInt64)
    case micStarted
    /// Offsets are relative to the session start.
    case micGapBegan(at: TimeInterval)
    case micGapEnded(at: TimeInterval)
    case micLost(String)
    /// `systemInitiated` = the "Stop Sharing" chip, a sleeping display, a lost
    /// screen — anything that was not our own `stop(reason:)`.
    case streamStopped(reason: String, systemInitiated: Bool)
    case writerFailed(String)
}

public enum ScreenRecorderError: Error, Sendable {
    /// `SCStreamErrorUserDeclined` (-3801).
    case userDeclined
    case noDisplay
    /// No `.screen` sample within `firstFrameTimeout` — the classic
    /// granted-but-stale TCC state.
    case noFirstFrame
    case shareableContentTimedOut
    case selfNotInShareableContent
    case writerSetupFailed(String)
    case writerFailed(String)
    case alreadyStarted
    /// Zero video frames appended; the file has been deleted.
    case nothingCaptured
    case finalizeTimedOut
}
