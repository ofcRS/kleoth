import AppKit
import Foundation
import KleothCore
import KleothPillUI

/// The ONE owner of the pill instance (design §3.4).
///
/// `DictationController` and `ScreenRecordingController` each get a face onto
/// it: dictation phases are FOREGROUND, a running screen recording is the
/// BACKDROP underneath them. The coordinator merges the two backdrops and fans
/// the pill's actions out to whichever side owns them.
///
/// Why a coordinator instead of two controllers sharing a pill: the pill has ONE
/// phase and ONE backdrop, and the two lanes are independent. Without a single
/// arbiter, a finished recording would paint `.saved` over a live `.listening`,
/// and dictation's `setResting(false)` (Settings → Dictation off) would hide the
/// indicator of a hot microphone. Both are decided here, in one place.
@MainActor
final class PillCoordinator {
    static let shared = PillCoordinator()

    /// The real pill. Every other surface goes through this object.
    let pill: DictationPillController

    /// Handed to `DictationController`'s designated init as `pill:`. It is a
    /// `DictationPillPresenting` that routes `setResting` into the backdrop
    /// merge and parks the dictation callbacks here for the fan-out.
    private let face: DictationFace

    var dictationFace: any DictationPillPresenting { face }

    /// Start / stop / reveal / open-Settings from the pill.
    /// `ScreenRecordingController` installs this in its `init`.
    var onRecordingAction: ((DictationPillAction) -> Void)?

    // MARK: - Merge inputs

    /// Mirrors `DictationController.isMonitoring` (fn+shift armed).
    private var dictationWantsResting = false
    /// The running session's fixed start, or nil when nothing records.
    private var recordingSince: Date?

    /// Which side put the pill's CURRENT phase up. Only `.warning` / `.failed`
    /// are ambiguous — both lanes use them — so this is what tells them apart.
    /// It is deliberately not consulted for the unambiguous phases: the pill
    /// auto-hides `.done` / `.warning` / `.saved` on its own timer without ever
    /// calling back, so `pill.currentState` is the only trustworthy answer
    /// there.
    private enum Owner { case dictation, recording }
    private var lastShowOwner: Owner?

    /// A `.saved` confirmation that arrived while a dictation phase was live
    /// (§2.4, §7 row 21). Shown after the dictation clears, dropped once older
    /// than `savedConfirmationMaxDelay`.
    private var queuedSaved: (text: String, at: Date)?
    private var queuedSavedTask: Task<Void, Never>?

    /// The dictation controller's own callbacks, parked by `face`.
    fileprivate var dictationAction: ((DictationPillAction) -> Void)?
    fileprivate var dictationDismiss: (() -> Void)?

    init(pill: DictationPillController = DictationPillController()) {
        self.pill = pill
        self.face = DictationFace(pill: pill)
        face.coordinator = self

        // The pill talks only to the coordinator; the coordinator fans out.
        pill.onAction = { [weak self] action in self?.route(action) }
        pill.onDismiss = { [weak self] in self?.routeDismiss() }
    }

    // MARK: - Recording side

    /// Non-nil → `.recording(since:)` outranks `.idle` in `recompute()`. The
    /// pill applies a backdrop immediately when no phase is live and otherwise
    /// at the next `dismiss()`, which is exactly the coexistence rule of §6.2.
    func setRecordingBackdrop(since: Date?) {
        guard recordingSince != since else { return }
        recordingSince = since
        recompute()
    }

    /// `.saving` / `.saved` / `.recording` / a recording `.warning` or
    /// `.failed`: applied now when no dictation phase is live, otherwise a
    /// `.saved` is QUEUED (≤ `savedConfirmationMaxDelay`) and anything else is
    /// dropped — a fault or a "saving" spinner painted over a live dictation
    /// would destroy the session the user is in the middle of (§7 rows 21, 22).
    func showRecordingPhase(_ state: DictationPillState) {
        guard !isDictationPhaseLive else {
            if case .saved(let text) = state { queueSaved(text) }
            return
        }
        lastShowOwner = .recording
        pill.show(state)
    }

    /// `pill.dismiss()` iff the pill is showing something the recording side put
    /// up. Never touches a dictation phase.
    func dismissRecordingPhase() {
        cancelQueuedSaved()
        guard !isDictationPhaseLive else { return }
        switch pill.currentState {
        case .saving, .saved:
            lastShowOwner = nil
            pill.dismiss()
        case .warning, .failed:
            guard lastShowOwner == .recording else { return }
            lastShowOwner = nil
            pill.dismiss()
        case .hidden, .idle, .armed, .listening, .transcribing, .polishing, .done, .recording:
            return
        }
    }

    /// Whether a DICTATION phase currently owns the pill — the recording side
    /// must never overwrite one.
    var isDictationPhaseLive: Bool {
        switch pill.currentState {
        case .armed, .listening, .transcribing, .polishing, .done:
            return true
        case .warning, .failed:
            return lastShowOwner == .dictation
        case .hidden, .idle, .recording, .saving, .saved:
            return false
        }
    }

    // MARK: - Merge

    /// A running recording outranks the dictation resting capsule, which
    /// outranks nothing at all (§6.1).
    private func recompute() {
        let backdrop: DictationPillBackdrop
        if let since = recordingSince {
            backdrop = .recording(since: since)
        } else {
            backdrop = dictationWantsResting ? .idle : .hidden
        }
        pill.setBackdrop(backdrop)
    }

    // MARK: - Queued `.saved`

    private func queueSaved(_ text: String) {
        queuedSaved = (text: text, at: Date())
        queuedSavedTask?.cancel()
        // A forwarded dictation `dismiss()` flushes this immediately. The poll
        // exists because the pill auto-hides `.done` and `.warning` on its own
        // `hideTask` WITHOUT calling `onDismiss` (DictationPillController's
        // `scheduleAutoHide` calls `dismiss()` directly), so those two very
        // common endings would otherwise never release the queue.
        queuedSavedTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, let queued = self.queuedSaved else { return }
                guard Date().timeIntervalSince(queued.at) <= ScreenRecordingDefaults.savedConfirmationMaxDelay
                else {
                    // Too late to be a confirmation of anything; the popover
                    // row still carries the file.
                    self.cancelQueuedSaved()
                    return
                }
                guard !self.isDictationPhaseLive else { continue }
                self.flushQueuedSaved()
                return
            }
        }
    }

    /// Shown after the dictation phase that blocked it has ended. No
    /// `isDictationPhaseLive` re-check on the `dismiss()` path: `pill.currentState`
    /// only catches up on the next main-queue turn (the transition's `Task`
    /// hop), so the caller's "the dictation just ended" is the fresher fact.
    private func flushQueuedSaved() {
        guard let queued = queuedSaved else { return }
        cancelQueuedSaved()
        guard Date().timeIntervalSince(queued.at) <= ScreenRecordingDefaults.savedConfirmationMaxDelay else { return }
        lastShowOwner = .recording
        pill.show(.saved(queued.text))
    }

    private func cancelQueuedSaved() {
        queuedSaved = nil
        queuedSavedTask?.cancel()
        queuedSavedTask = nil
    }

    // MARK: - Fan-out

    private func route(_ action: DictationPillAction) {
        switch action {
        case .startScreenRecording, .stopScreenRecording, .revealLastRecording,
             .openScreenRecordingSettings:
            onRecordingAction?(action)
        case .openSettings, .openAccessibilitySettings:
            dictationAction?(action)
        }
    }

    /// ✕ or a click on a sticky `.failed`. A recording fault must not reach
    /// `DictationController.handlePillDismiss`, which would cancel a dictation
    /// session that has nothing to do with it.
    private func routeDismiss() {
        if isDictationPhaseLive {
            lastShowOwner = nil
            dictationDismiss?()
            flushQueuedSaved()
        } else {
            lastShowOwner = nil
            cancelQueuedSaved()
        }
    }

    // MARK: - Dictation side (called by `face`)

    fileprivate func dictationDidShow(_ state: DictationPillState) {
        lastShowOwner = .dictation
        pill.show(state)
    }

    fileprivate func dictationDidDismiss() {
        lastShowOwner = nil
        pill.dismiss()
        // §2.4: the queued confirmation is shown after the dictation's own
        // `dismiss()`, replacing the backdrop it just collapsed onto.
        flushQueuedSaved()
    }

    fileprivate func dictationDidSetResting(_ visible: Bool) {
        guard dictationWantsResting != visible else { return }
        dictationWantsResting = visible
        recompute()
    }
}

/// The `DictationPillPresenting` the dictation controller talks to.
///
/// It is NOT a transparent forwarder: `show` / `dismiss` / `setResting` go
/// through the coordinator so the merge and the ownership bookkeeping see them,
/// and `onAction` / `onDismiss` are parked on the coordinator rather than
/// clobbering `pill.onAction`, which the fan-out owns.
@MainActor
private final class DictationFace: DictationPillPresenting {
    private let pill: DictationPillController
    /// Set immediately after construction. Weak, not unowned: the coordinator
    /// owns this object, and `shared` lives for the app's lifetime anyway.
    weak var coordinator: PillCoordinator?

    init(pill: DictationPillController) {
        self.pill = pill
    }

    var onAction: ((DictationPillAction) -> Void)? {
        get { coordinator?.dictationAction }
        set { coordinator?.dictationAction = newValue }
    }

    var onDismiss: (() -> Void)? {
        get { coordinator?.dictationDismiss }
        set { coordinator?.dictationDismiss = newValue }
    }

    func show(_ state: DictationPillState) { coordinator?.dictationDidShow(state) }
    func setLevel(_ level: Double) { pill.setLevel(level) }
    func dismiss() { coordinator?.dictationDidDismiss() }
    func setResting(_ visible: Bool) { coordinator?.dictationDidSetResting(visible) }
    func resetPosition() { pill.resetPosition() }
}
