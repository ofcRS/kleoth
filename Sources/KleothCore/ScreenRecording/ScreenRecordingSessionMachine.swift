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

    /// The instant the user asked for a recording, carried across the
    /// permission and picker legs so `.starting`/`.recording` can hand the pill
    /// ONE fixed start date. The elapsed clock has to count from the click, not
    /// from whenever `SCStream` finally produced its first frame — otherwise
    /// the digits jump backwards the moment capture starts.
    private var pendingSince: Date?

    public init() {
        state = .idle
    }

    /// The whole transition table. Anything not listed is a rejection: `nil`,
    /// state untouched, no trap — this is driven from callback threads and from
    /// `applicationWillTerminate`, where an unhandled pair would be a crash on
    /// quit rather than a lost frame.
    @discardableResult
    public mutating func apply(_ event: Event) -> Effect? {
        switch (state, event) {

        // Start — only from a state with no session in flight. A finished
        // `.saved` / `.failed` is replaced, so the confirmation pill never
        // blocks the next recording.
        case (.idle, .startRequested(let since)),
             (.saved, .startRequested(let since)),
             (.failed, .startRequested(let since)):
            pendingSince = since
            state = .checkingPermission
            return .requestPermission

        // Permission.
        case (.checkingPermission, .permissionOK):
            state = .pickingRegion
            return .presentPicker
        case (.checkingPermission, .permissionMissing(let failure)):
            return fail(failure)

        // Region picking. Esc is a full cancel: no capture ever started, so
        // there is nothing to finalize and no file to clean up.
        case (.pickingRegion, .regionPicked):
            state = .starting(since: pendingSince ?? Date())
            return .startCapture
        case (.pickingRegion, .regionCancelled):
            return reset()

        // Capture coming up. The pill already shows `.recording` here (§2.1
        // step 5); `captureStarted` only confirms it.
        case (.starting, .captureStarted):
            state = .recording(since: pendingSince ?? Date())
            return .showRecording
        case (.starting, .captureDidNotStart(let failure)):
            return fail(failure)

        // Stop. From `.starting` too — the user clicked stop while the stream
        // was still coming up and still expects a file, so the request is
        // carried into `.stopping` instead of being dropped. A late
        // `captureStarted` afterwards is rejected below and cannot resurrect it.
        case (.starting, .stopRequested(let reason)),
             (.recording, .stopRequested(let reason)):
            pendingSince = nil
            state = .stopping(reason: reason)
            return .stopCapture

        // Quit (or any stop) before there is a capture: unwind, do not pretend
        // to finalize a writer that was never opened (§2.7).
        case (.checkingPermission, .stopRequested),
             (.pickingRegion, .stopRequested):
            return reset()

        // Finalize.
        case (.stopping, .captureStopped):
            state = .saving
            return .finalize
        case (.saving, .finalized(let summary)):
            state = .saved(summary)
            pendingSince = nil
            return .showSaved
        case (.saving, .finalizeFailed(let failure)):
            return fail(failure)

        // The confirmation pill timing out, or the user clicking it away.
        // Deliberately NOT accepted while a session is in flight: an auto-hide
        // must never silently abandon a running capture.
        case (.saved, .dismissed), (.failed, .dismissed):
            return reset()

        default:
            return nil
        }
    }

    /// Every failure leg lands the same way — the reason is the only difference,
    /// and it is the controller's to map onto the §7 error matrix.
    private mutating func fail(_ failure: ScreenRecordingFailure) -> Effect {
        pendingSince = nil
        state = .failed(failure)
        return .showFailed
    }

    private mutating func reset() -> Effect {
        pendingSince = nil
        state = .idle
        return .reset
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
