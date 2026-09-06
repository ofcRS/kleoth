import Foundation

/// The screen-recording session's life as a pure machine — the same role
/// `DictationChordMachine` plays for the hotkey (design §3.1).
///
/// Every controller transition goes through `apply`: it is TOTAL (every
/// `State × Event` pair has a defined result), illegal events are rejected
/// (`nil` effect, state unchanged) and never crashed on, and the returned
/// `Effect` is the controller's to-do list for that step. Keeping it pure is
/// what makes the async, permission-gated, cancellable start path testable
/// without a display.
///
/// **T0 STUB** — the surface is final; `apply` is a no-op that returns nil.
/// T1 implements the transition table and its tests.
public struct ScreenRecordingSessionMachine: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case checkingPermission
        case pickingRegion
        /// Capture requested; the pill already shows `.recording` from here
        /// (§2.1 step 5) so the click feels instant.
        case starting(since: Date)
        case recording(since: Date)
        case stopping(reason: ScreenRecordingStopReason)
        case saving
        case saved(ScreenRecordingSummary)
        case failed(ScreenRecordingFailure)
    }

    public enum Event: Equatable, Sendable {
        case startRequested(Date)
        case permissionOK
        case permissionMissing(ScreenRecordingFailure)
        case regionPicked
        case regionCancelled
        case captureStarted
        case captureDidNotStart(ScreenRecordingFailure)
        case stopRequested(ScreenRecordingStopReason)
        case captureStopped
        case finalized(ScreenRecordingSummary)
        case finalizeFailed(ScreenRecordingFailure)
        case dismissed
    }

    public enum Effect: Equatable, Sendable {
        case requestPermission
        case presentPicker
        case startCapture
        case showRecording
        case stopCapture
        case finalize
        case showSaved
        case showFailed
        case reset
    }

    public private(set) var state: State

    public init() {
        state = .idle
    }

    /// TODO(T1): the transition table from TASKS.md ("Required transitions").
    /// Stubbed as a rejection of everything so T0 compiles without pretending
    /// to work — the controller lanes are stubs too.
    @discardableResult
    public mutating func apply(_ event: Event) -> Effect? {
        _ = event
        return nil
    }

    /// Anything but `idle` / `saved` / `failed`: a session is in flight, so a
    /// second start is refused and the quit guard engages.
    public var isActive: Bool {
        switch state {
        case .idle, .saved, .failed: return false
        case .checkingPermission, .pickingRegion, .starting, .recording, .stopping, .saving: return true
        }
    }

    /// The session's fixed start instant, once one exists — the pill's
    /// `.recording(since:)` payload and the popover's elapsed digits.
    public var since: Date? {
        switch state {
        case .starting(let since), .recording(let since): return since
        case .idle, .checkingPermission, .pickingRegion, .stopping, .saving, .saved, .failed: return nil
        }
    }
}
