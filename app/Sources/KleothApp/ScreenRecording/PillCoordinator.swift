import AppKit
import Foundation
import KleothCore
import KleothPillUI

/// The ONE owner of the pill instance (design §3.4).
///
/// `DictationController`, `ScreenRecordingController` and `MeetingPillBridge`
/// each get a face onto it: dictation phases are FOREGROUND, a running screen
/// recording or meeting is the BACKDROP underneath them. The coordinator merges
/// the backdrops and fans the pill's actions out to whichever side owns them.
///
/// Why a coordinator instead of controllers sharing a pill: the pill has ONE
/// phase and ONE backdrop, and the lanes are independent. Without a single
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
    /// The meeting side's actions; `MeetingPillBridge` installs this.
    var onMeetingAction: ((MeetingPillAction) -> Void)?

    // MARK: - Merge inputs

    /// Mirrors `DictationController.isMonitoring` (fn+shift armed).
    private var dictationWantsResting = false
    /// The running session's fixed start, or nil when nothing records.
    private var recordingSince: Date?
    /// The running meeting's fixed start, or nil when no meeting records.
    private var meetingSince: Date?

    /// Which side put the pill's CURRENT phase up. Only `.saving` (screen
    /// recording, meeting), `.warning` and `.failed` (all three) are ambiguous,
    /// so this is what tells them apart. It is never trusted on its own: the
    /// pill auto-hides `.done` / `.warning` / `.saved` / `.meetingSaved` on its
    /// own timer without ever calling back, so an owner can outlive its phase —
    /// `pill.currentState` says WHAT is up, this only says whose it is.
    private enum Owner { case dictation, recording, meeting }
    private var lastShowOwner: Owner?

    /// A confirmation (`.saved` / `.meetingSaved`) that arrived while a
    /// dictation phase was live (screen-recording §2.4, §7 row 21; meetings
    /// §3.1.5). ONE slot: the newer one wins — two captures ending under the
    /// same dictation is rare, and the popover / History still carry both.
    /// Shown after the dictation clears, dropped once older than
    /// `savedConfirmationMaxDelay`.
    private var queuedConfirmation: (state: DictationPillState, owner: Owner, at: Date)?
    private var queuedConfirmationTask: Task<Void, Never>?

    /// The dictation controller's own callbacks, parked by `face`.
    fileprivate var dictationAction: ((DictationPillAction) -> Void)?
    fileprivate var dictationDismiss: (() -> Void)?
    fileprivate var dictationMenuContent: (() -> PillMenuContent)?

    init(pill: DictationPillController = DictationPillController()) {
        self.pill = pill
        self.face = DictationFace(pill: pill)
        face.coordinator = self

        // The pill talks only to the coordinator; the coordinator fans out.
        pill.onAction = { [weak self] action in self?.route(action) }
        pill.onDismiss = { [weak self] in self?.routeDismiss() }
        // The coordinator owns the menu's content too, so the meeting row sees
        // every meeting — whoever started it, dictation on or off.
        pill.menuContent = { [weak self] in
            var content = self?.dictationMenuContent?() ?? PillMenuContent()
            content.meetingSince = self?.meetingSince
            return content
        }
    }

    // MARK: - Recording side

    /// Non-nil → `.recording(since:)` outranks `.meeting` and `.idle` in
    /// `recompute()`. The pill applies a backdrop immediately when no phase is
    /// live and otherwise at the next `dismiss()`, which is exactly the
    /// coexistence rule of §6.2.
    func setRecordingBackdrop(since: Date?) {
        guard recordingSince != since else { return }
        let rising = recordingSince == nil && since != nil
        recordingSince = since
        recompute()                                               // the new backdrop is stored FIRST…
        if rising { clearCapturePhaseBlocking(.recording) }       // …then the collapse lands on it
    }

    /// Live meters for the `.recording` toolbar — a straight pass-through; the
    /// pill ignores levels while a dictation phase is showing.
    func setRecordingLevels(_ levels: AudioLevels) {
        pill.setRecordingLevels(levels)
    }

    /// `.saving` / `.saved` / `.recording` / a recording `.warning` or
    /// `.failed`: applied now when no dictation phase is live, otherwise a
    /// `.saved` is QUEUED (≤ `savedConfirmationMaxDelay`) and anything else is
    /// dropped — a fault or a "saving" spinner painted over a live dictation
    /// would destroy the session the user is in the middle of (§7 rows 21, 22).
    func showRecordingPhase(_ state: DictationPillState) {
        guard !isDictationPhaseLive else {
            if case .saved = state { queueConfirmation(state, owner: .recording) }
            return
        }
        lastShowOwner = .recording
        pill.show(state)
    }

    /// `pill.dismiss()` iff the pill is showing something the recording side put
    /// up. Never touches a dictation phase or a meeting's phase.
    func dismissRecordingPhase() {
        if queuedConfirmation?.owner == .recording { cancelQueuedConfirmation() }
        guard !isDictationPhaseLive else { return }
        switch pill.currentState {
        case .saved:
            lastShowOwner = nil
            pill.dismiss()
        case .saving, .warning, .failed:
            guard lastShowOwner == .recording else { return }
            lastShowOwner = nil
            pill.dismiss()
        case .hidden, .idle, .armed, .listening, .transcribing, .polishing, .done, .recording,
             .meeting, .meetingSaved:
            return
        }
    }

    // MARK: - Meeting side

    /// ✕ on a meeting-owned `.failed`.
    var onMeetingDismiss: (() -> Void)?

    /// Non-nil → `.meeting(since:)` sits between `.recording` and `.idle`.
    /// Call it BEFORE dismissing anything at a meeting's start: the pill's
    /// `model.phase` changes a main-queue turn after a `dismiss()`, so a
    /// backdrop set right after one is merely stored and the bar never rises.
    func setMeetingBackdrop(since: Date?) {
        guard meetingSince != since else { return }
        meetingSince = since
        recompute()                                               // the new backdrop is stored FIRST…
        if since != nil { clearCapturePhaseBlocking(.meeting) }   // …then the collapse lands on it
    }

    /// The meeting bar's meters. Dropped while a screen recording runs: its
    /// bar is up instead and its own pump feeds the meters.
    func setMeetingLevels(_ levels: AudioLevels) {
        guard recordingSince == nil else { return }
        pill.setRecordingLevels(levels)
    }

    /// `.saving` / `.meetingSaved` / a meeting `.warning` or `.failed`. The
    /// recording side's rule: never over a live dictation — `.meetingSaved`
    /// is queued (≤ `savedConfirmationMaxDelay`), anything else is dropped.
    /// And precedence (meetings §3.1.5, screen recording > meeting): while a
    /// screen recording runs, the meeting's save sequence is not shown at all
    /// — its bar stays up and the popover / History carry the saved meeting.
    /// (A meeting save already up when the screen recording started was
    /// withdrawn then, by `clearCapturePhaseBlocking(.recording)`.)
    /// Returns false when nothing was shown.
    @discardableResult
    func showMeetingPhase(_ state: DictationPillState) -> Bool {
        if meetingPhaseYieldsToScreenRecording(state) { return false }
        guard !isDictationPhaseLive else {
            if case .meetingSaved = state { queueConfirmation(state, owner: .meeting) }
            return false
        }
        lastShowOwner = .meeting
        pill.show(state)
        return true
    }

    /// `pill.dismiss()` iff the pill shows something the meeting side put up.
    /// Never touches a dictation phase or a recording's phase.
    func dismissMeetingPhase() {
        if queuedConfirmation?.owner == .meeting { cancelQueuedConfirmation() }
        guard !isDictationPhaseLive else { return }
        switch pill.currentState {
        case .saving, .meetingSaved, .warning, .failed:
            guard lastShowOwner == .meeting else { return }
            lastShowOwner = nil
            pill.dismiss()
        case .hidden, .idle, .armed, .listening, .transcribing, .polishing, .done, .recording, .saved,
             .meeting:
            return
        }
    }

    /// Precedence for the meeting's save sequence: `.saving` and
    /// `.meetingSaved` never cover a running screen recording's bar (or its
    /// own saving / saved phases, which run while `recordingSince` is still
    /// set). A meeting `.warning` / `.failed` still shows — a fault the user
    /// has to see; its ✕ collapses back onto the screen bar.
    private func meetingPhaseYieldsToScreenRecording(_ state: DictationPillState) -> Bool {
        guard recordingSince != nil else { return false }
        switch state {
        case .saving, .meetingSaved:
            return true
        case .hidden, .idle, .armed, .listening, .transcribing, .polishing, .done, .warning, .failed,
             .recording, .saved, .meeting:
            return false
        }
    }

    /// A capture's bar just became due, but `setBackdrop` only takes over a
    /// resting-family phase: a leftover capture phase would leave a hot
    /// microphone with no bar (meetings §3.1.3, screen recording §6.3).
    /// Withdraw it; the popover / History keep the detail. This is
    /// `ScreenRecordingController.start(from:)`'s rule (§7 rows 21-22),
    /// extended to both captures:
    /// - either side's sticky `.failed`;
    /// - the meeting's own leftovers (`.saving`, `.meetingSaved`, `.warning`) —
    ///   a screen `.saved` / `.warning` auto-hides within 4 s on its own, and a
    ///   screen `.saving` can't be up while a meeting rises to the top, since
    ///   `recordingSince` is still set during that save.
    /// Never touches a dictation phase, and a meeting rising under a running
    /// screen recording changes nothing: the screen bar stays on top.
    private func clearCapturePhaseBlocking(_ rising: Owner) {
        guard !isDictationPhaseLive, let owner = lastShowOwner else { return }
        if rising == .meeting, recordingSince != nil { return }
        switch pill.currentState {
        case .failed:
            guard owner == .meeting || owner == .recording else { return }
        case .saving, .meetingSaved, .warning:
            guard owner == .meeting else { return }
        case .hidden, .idle, .armed, .listening, .transcribing, .polishing, .done, .recording, .saved,
             .meeting:
            return
        }
        lastShowOwner = nil
        pill.dismiss()
    }

    /// Whether a DICTATION phase currently owns the pill — neither capture
    /// side may overwrite one.
    var isDictationPhaseLive: Bool {
        switch pill.currentState {
        case .armed, .listening, .transcribing, .polishing, .done:
            return true
        case .warning, .failed:
            return lastShowOwner == .dictation
        case .hidden, .idle, .recording, .saving, .saved, .meeting, .meetingSaved:
            return false
        }
    }

    // MARK: - Merge

    /// Screen recording > meeting > the dictation resting capsule > nothing
    /// (screen-recording §6.1, meetings §3.1.5). A meeting shows even with
    /// dictation off or the pill hidden for the hour (the hot-mic rule), and
    /// when it stops the pill falls back to exactly what dictation wants —
    /// `.hidden` stays hidden, never `.idle`.
    private func recompute() {
        let backdrop: DictationPillBackdrop
        if let since = recordingSince {
            backdrop = .recording(since: since)
        } else if let since = meetingSince {
            backdrop = .meeting(since: since)
        } else {
            backdrop = dictationWantsResting ? .idle : .hidden
        }
        pill.setBackdrop(backdrop)
    }

    // MARK: - Queued confirmation

    private func queueConfirmation(_ state: DictationPillState, owner: Owner) {
        queuedConfirmation = (state: state, owner: owner, at: Date())
        queuedConfirmationTask?.cancel()
        // A forwarded dictation `dismiss()` flushes this immediately. The poll
        // exists because the pill auto-hides `.done` and `.warning` on its own
        // `hideTask` WITHOUT calling `onDismiss` (DictationPillController's
        // `scheduleAutoHide` calls `dismiss()` directly), so those two very
        // common endings would otherwise never release the queue.
        queuedConfirmationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, let queued = self.queuedConfirmation else { return }
                guard Date().timeIntervalSince(queued.at) <= ScreenRecordingDefaults.savedConfirmationMaxDelay
                else {
                    // Too late to be a confirmation of anything; the popover
                    // row / History still carry the file.
                    self.cancelQueuedConfirmation()
                    return
                }
                guard !self.isDictationPhaseLive else { continue }
                self.flushQueuedConfirmation()
                return
            }
        }
    }

    /// Shown after the dictation phase that blocked it has ended. No
    /// `isDictationPhaseLive` re-check on the `dismiss()` path: `pill.currentState`
    /// only catches up on the next main-queue turn (the transition's `Task`
    /// hop), so the caller's "the dictation just ended" is the fresher fact.
    /// A queued `.meetingSaved` is dropped if a screen recording started in
    /// the meantime (precedence, as in `showMeetingPhase`).
    private func flushQueuedConfirmation() {
        guard let queued = queuedConfirmation else { return }
        cancelQueuedConfirmation()
        guard Date().timeIntervalSince(queued.at) <= ScreenRecordingDefaults.savedConfirmationMaxDelay else { return }
        if queued.owner == .meeting, meetingPhaseYieldsToScreenRecording(queued.state) { return }
        lastShowOwner = queued.owner
        pill.show(queued.state)
    }

    private func cancelQueuedConfirmation() {
        queuedConfirmation = nil
        queuedConfirmationTask?.cancel()
        queuedConfirmationTask = nil
    }

    // MARK: - Fan-out

    private func route(_ action: DictationPillAction) {
        switch action {
        case .startScreenRecording, .stopScreenRecording, .revealLastRecording,
             .openScreenRecordingSettings:
            onRecordingAction?(action)
        case .meeting(let action):
            onMeetingAction?(action)
        case .openSettings, .openAccessibilitySettings,
             .startHandsFreeDictation, .stopHandsFreeDictation, .switchToHandsFree, .selectMicrophone,
             .pasteLastDictation, .openDictationHistory, .hideForAnHour, .retryTranscription:
            dictationAction?(action)
        }
    }

    /// ✕ or a click on a sticky `.failed`. A recording or meeting fault must
    /// not reach `DictationController.handlePillDismiss`, which would cancel a
    /// dictation session that has nothing to do with it.
    private func routeDismiss() {
        if isDictationPhaseLive {
            lastShowOwner = nil
            dictationDismiss?()
            flushQueuedConfirmation()
        } else if lastShowOwner == .meeting {
            lastShowOwner = nil
            onMeetingDismiss?()
        } else {
            lastShowOwner = nil
            cancelQueuedConfirmation()
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
        flushQueuedConfirmation()
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
/// and `onAction` / `onDismiss` / `menuContent` are parked on the coordinator
/// rather than clobbering the pill's own, which the fan-out owns.
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

    /// Parked here; the coordinator's own closure adds `meetingSince`.
    var menuContent: (() -> PillMenuContent)? {
        get { coordinator?.dictationMenuContent }
        set { coordinator?.dictationMenuContent = newValue }
    }

    func show(_ state: DictationPillState) { coordinator?.dictationDidShow(state) }
    func setLevel(_ level: Double) { pill.setLevel(level) }
    func dismiss() { coordinator?.dictationDidDismiss() }
    func setResting(_ visible: Bool) { coordinator?.dictationDidSetResting(visible) }
    func resetPosition() { pill.resetPosition() }
}
