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
    /// It stays set from the stop until `.saved` — the bar under `.saving` —
    /// so the menu asks `meetingRecording` instead.
    private var meetingSince: Date?
    /// The meeting behind `meetingSince` still records: false from its
    /// `.finalizing` (`meetingDidStopRecording`), true again at the next start.
    private var meetingRecording = false

    /// Which side put the pill's CURRENT phase up. Only `.saving` (screen
    /// recording, meeting), `.warning` and `.failed` (all three) are ambiguous,
    /// so this is what tells them apart. It is never trusted on its own: the
    /// pill auto-hides `.done` / `.warning` / `.saved` / `.meetingSaved` on its
    /// own timer without ever calling back, so an owner can outlive its phase —
    /// `pill.currentState` says WHAT is up, this only says whose it is.
    private enum Owner { case dictation, recording, meeting }
    private var lastShowOwner: Owner?

    /// The last phase the coordinator asked the pill for, whose, and when
    /// (every `pill.show` goes through `present`). `pill.currentState` only
    /// catches up a main-queue turn after a `show()` on a panel that is
    /// already up (the transition's `Task` hop), so for that turn this is the
    /// fresher fact: the meeting prompt on the pill and whether a phase that
    /// is about to land keeps prompts out.
    private var lastShown: (state: DictationPillState, owner: Owner, at: Date)?
    /// How long a phase just asked for counts as up for `isPillBusyForPrompts`
    /// — a turn is what it needs; this is generous, and a wrong "busy" costs a
    /// prompt one 1 s retry.
    private static let phaseLandingWindow: TimeInterval = 0.5

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
        // every meeting — whoever started it, dictation on or off. "Stop" only
        // while it records: during its save the row offers the next meeting.
        pill.menuContent = { [weak self] in
            var content = self?.dictationMenuContent?() ?? PillMenuContent()
            content.meetingSince = self?.meetingRecording == true ? self?.meetingSince : nil
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
        present(state, owner: .recording)
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
             .meeting, .meetingSaved, .prompt:
            return
        }
    }

    // MARK: - Meeting side

    /// ✕ on a meeting-owned phase: a prompt's ✕ carries its id, a `.failed`'s
    /// ✕ (or click) carries nil.
    var onMeetingDismiss: ((String?) -> Void)?

    /// A meeting prompt (its id) was replaced or withdrawn by something other
    /// than the meeting side itself — a dictation phase, a recording phase, a
    /// capture bar rising, a dictation dismiss, the meeting's own save. The
    /// detector hears `.displaced` and asks again once the pill is free; it
    /// must never keep believing a prompt is visible that the pill dropped.
    var onMeetingPromptDisplaced: ((String) -> Void)?

    /// The meeting prompt on the pill, or asked for within the last
    /// `phaseLandingWindow` and not landed yet; nil for anything else. Not
    /// `pill.currentState` alone: it lags a turn behind a show, and a withdraw
    /// right after a show must still find its prompt. A `.prompt` never
    /// auto-hides, and every path that takes one down goes through the
    /// coordinator and moves `lastShowOwner`; a prompt the pill never landed
    /// (a capture bar took the panel over in that turn) stops counting once
    /// the window has passed.
    var currentMeetingPromptId: String? {
        guard lastShowOwner == .meeting, let shown = lastShown, shown.owner == .meeting,
              let id = shown.state.promptId else { return nil }
        if pill.currentState.promptId == id { return id }
        return Date().timeIntervalSince(shown.at) < Self.phaseLandingWindow ? id : nil
    }

    /// Whether a meeting prompt has to wait: a dictation phase, a recording
    /// or meeting `.saving`/`.saved`/`.meetingSaved`/`.warning`/`.failed`, a
    /// confirmation queued behind a dictation, or the dock / menu under the
    /// pointer. A phase asked for in the last `phaseLandingWindow` counts as
    /// up (the pill applies it a turn late) — e.g. a dictation's `.armed`
    /// over a prompt. Not "the last owner is dictation": that owner outlives
    /// `.done` / `.warning`, which the pill hides on its own timer.
    var isPillBusyForPrompts: Bool {
        if isDictationPhaseLive || pill.isInteracting || queuedConfirmation != nil { return true }
        if Self.holdsPrompts(pill.currentState) { return true }
        if let shown = lastShown, Date().timeIntervalSince(shown.at) < Self.phaseLandingWindow,
           Self.holdsPrompts(shown.state) {
            return true
        }
        return false
    }

    /// Whether `showMeetingPhase(.prompt(…))` would show a prompt now: no
    /// screen recording (a prompt yields to its bar) and not
    /// `isPillBusyForPrompts`. The detection host asks BEFORE composing an
    /// offer, whose text can cost a calendar lookup.
    var acceptsMeetingPrompt: Bool { recordingSince == nil && !isPillBusyForPrompts }

    /// The pointer is on the pill: a visible prompt's lifetime waits.
    var isPointerOverPill: Bool { pill.isPointerOver }

    /// The phases a meeting prompt never replaces. A prompt replaces only the
    /// resting family (`.hidden`, `.idle`, `.recording`, `.meeting`) or
    /// another meeting prompt.
    private static func holdsPrompts(_ state: DictationPillState) -> Bool {
        switch state {
        case .armed, .listening, .transcribing, .polishing, .done,
             .saving, .saved, .meetingSaved, .warning, .failed:
            return true
        case .hidden, .idle, .recording, .meeting, .prompt:
            return false
        }
    }

    /// Non-nil → `.meeting(since:)` sits between `.recording` and `.idle`.
    /// Call it BEFORE dismissing anything at a meeting's start: the pill's
    /// `model.phase` changes a main-queue turn after a `dismiss()`, so a
    /// backdrop set right after one is merely stored and the bar never rises.
    func setMeetingBackdrop(since: Date?) {
        guard meetingSince != since else { return }
        meetingSince = since
        meetingRecording = since != nil
        recompute()                                               // the new backdrop is stored FIRST…
        if since != nil { clearCapturePhaseBlocking(.meeting) }   // …then the collapse lands on it
    }

    /// The meeting stopped recording (`.finalizing`): its bar stays up under
    /// `.saving` until `.saved`, but the menu no longer offers to stop it.
    func meetingDidStopRecording() {
        meetingRecording = false
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
    /// withdrawn then, by `clearCapturePhaseBlocking(.recording)`.) A
    /// `.prompt` shows only over the resting family or another meeting prompt
    /// (`isPillBusyForPrompts`). Returns false when nothing was shown — for a
    /// prompt, a refusal the detector retries.
    @discardableResult
    func showMeetingPhase(_ state: DictationPillState) -> Bool {
        if meetingPhaseYieldsToScreenRecording(state) { return false }
        if case .prompt = state {
            guard !isPillBusyForPrompts else { return false }
        }
        guard !isDictationPhaseLive else {
            if case .meetingSaved = state { queueConfirmation(state, owner: .meeting) }
            return false
        }
        present(state, owner: .meeting)
        return true
    }

    /// `pill.dismiss()` iff the pill shows something the meeting side put up.
    /// Never touches a dictation phase or a recording's phase.
    func dismissMeetingPhase() {
        if queuedConfirmation?.owner == .meeting { cancelQueuedConfirmation() }
        guard !isDictationPhaseLive else { return }
        if let id = currentMeetingPromptId, pill.currentState.promptId != id {
            // A prompt asked for this turn has not landed yet (`currentState`
            // lags a turn behind a `show` on a panel that is up), so the switch
            // below would find the backdrop and leave it. The pill's own
            // `dismiss()` handles it: it sees the phase still to land and
            // collapses onto the backdrop over it, so the prompt never appears.
            lastShowOwner = nil
            pill.dismiss()
            return
        }
        dismissLandedMeetingPhase()
    }

    private func dismissLandedMeetingPhase() {
        switch pill.currentState {
        case .saving, .meetingSaved, .warning, .failed, .prompt:
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
    /// A meeting `.prompt` yields too: no call is offered while a screen
    /// recording runs (§3.2.3), and a stop suggestion's "Stop" over the SCREEN
    /// bar would read as stopping the screen recording. The caller gets
    /// `false` (a refusal) and asks again once the screen bar is gone.
    private func meetingPhaseYieldsToScreenRecording(_ state: DictationPillState) -> Bool {
        guard recordingSince != nil else { return false }
        switch state {
        case .saving, .meetingSaved, .prompt:
            return true
        case .hidden, .idle, .armed, .listening, .transcribing, .polishing, .done, .warning, .failed,
             .recording, .saved, .meeting:
            return false
        }
    }

    /// A capture's bar just became due, but `setBackdrop` only takes over a
    /// resting-family phase: a leftover phase would leave a hot microphone with
    /// no bar (meetings §3.1.3, screen recording §6.3). Withdraw it; the
    /// popover / History keep the detail. This is
    /// `ScreenRecordingController.start(from:)`'s rule (§7 rows 21-22),
    /// extended to both captures:
    /// - ANY side's sticky `.failed` — a dictation's too: it is terminal
    ///   (its session has ended; a `.transcriptionKept` Retry is also
    ///   History's "Try again"), and a stale "Add an ElevenLabs key" must never
    ///   hide a new recording's bar;
    /// - the meeting's own leftovers (`.saving`, `.meetingSaved`, `.warning`) —
    ///   a screen `.saved` / `.warning` auto-hides within 4 s on its own, and a
    ///   screen `.saving` can't be up while a meeting rises to the top, since
    ///   `recordingSince` is still set during that save;
    /// - a meeting `.prompt` (sticky): an offer is withdrawn when a meeting or
    ///   a screen recording starts (§3.2.3), and a stop suggestion must not keep
    ///   a starting screen recording's bar down for its 60 s. The detector is
    ///   told (`onMeetingPromptDisplaced`), after the dismiss.
    /// Never a live dictation phase, nor a dictation's `.warning` (it hides
    /// itself in 3 s and the stored bar lands then), and a meeting rising
    /// under a running screen recording changes nothing: the screen bar stays
    /// on top. Read from `upcomingState`, as `setBackdrop` reads it: a phase
    /// asked for this turn is the one that keeps the bar stored.
    private func clearCapturePhaseBlocking(_ rising: Owner) {
        guard let owner = lastShowOwner else { return }
        if rising == .meeting, recordingSince != nil { return }
        switch pill.upcomingState {
        case .failed:
            break   // any side's sticky fault; a dictation's is terminal — its session has ended
        case .saving, .meetingSaved, .warning, .prompt:
            guard owner == .meeting else { return }
        case .hidden, .idle, .armed, .listening, .transcribing, .polishing, .done, .recording, .saved,
             .meeting:
            return
        }
        let displaced = currentMeetingPromptId
        lastShowOwner = nil
        pill.dismiss()
        if let displaced { onMeetingPromptDisplaced?(displaced) }
    }

    /// Whether a DICTATION phase currently owns the pill — neither capture
    /// side may overwrite one. Includes a phase asked for this turn that has
    /// not landed (`upcomingState`): a meeting `.saving` right after a
    /// dictation's `.armed` must not pre-empt it.
    var isDictationPhaseLive: Bool {
        switch pill.upcomingState {
        case .armed, .listening, .transcribing, .polishing, .done:
            return true
        case .warning, .failed:
            return lastShowOwner == .dictation
        case .hidden, .idle, .recording, .saving, .saved, .meeting, .meetingSaved, .prompt:
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
        present(queued.state, owner: queued.owner)
    }

    // MARK: - Showing

    /// Every `pill.show` the coordinator makes. A meeting prompt this replaces
    /// is read BEFORE the owner flips (after it, `currentMeetingPromptId` is
    /// nil) and reported AFTER the new phase is asked for: a detector that
    /// re-offers on `.displaced` (the stop suggestion does, synchronously)
    /// then finds the pill busy with the new phase (`lastShown`) and is
    /// refused — reported first, its prompt would be painted and immediately
    /// covered by this phase, while the detector believed it visible.
    private func present(_ state: DictationPillState, owner: Owner) {
        let displaced = currentMeetingPromptId
        lastShowOwner = owner
        lastShown = (state: state, owner: owner, at: Date())
        pill.show(state)
        if let displaced, displaced != state.promptId { onMeetingPromptDisplaced?(displaced) }
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

    /// ✕ or a click on a sticky `.failed`, or a meeting prompt's ✕. A
    /// recording or meeting fault must not reach
    /// `DictationController.handlePillDismiss`, which would cancel a dictation
    /// session that has nothing to do with it.
    private func routeDismiss() {
        if isDictationPhaseLive {
            lastShowOwner = nil
            dictationDismiss?()
            flushQueuedConfirmation()
        } else if lastShowOwner == .meeting {
            // The pill keeps reporting the dismissed phase for the callback
            // (`dismissFromUser`), so this is the prompt the ✕ was on.
            let id = pill.currentState.promptId
            lastShowOwner = nil
            onMeetingDismiss?(id)
        } else {
            lastShowOwner = nil
            cancelQueuedConfirmation()
        }
    }

    // MARK: - Dictation side (called by `face`)

    /// `.armed` on every chord: a meeting prompt goes on the first frame and
    /// comes back once the pill is free (§3.2.3), via `present`'s report.
    /// A dictation over a meeting's `.saving`: that meeting has stopped, so
    /// its bar goes now — the dictation would otherwise collapse back onto a
    /// running clock with a Stop that answers "Nothing is recording" until
    /// `.saved`. It collapses onto the resting pill (or nothing) instead, and
    /// `.meetingSaved` is queued behind it as usual.
    fileprivate func dictationDidShow(_ state: DictationPillState) {
        if case .saving = pill.upcomingState, lastShowOwner == .meeting, meetingSince != nil {
            meetingSince = nil
            meetingRecording = false
            recompute()   // stored only: `.saving` is still up
        }
        present(state, owner: .dictation)
    }

    /// Also reached with no dictation phase up (`DictationController.cancel()`
    /// in `.idle`, e.g. dictation switched off in Settings): a meeting prompt
    /// it collapses is reported, so the detector offers it again.
    fileprivate func dictationDidDismiss() {
        let displaced = currentMeetingPromptId
        lastShowOwner = nil
        pill.dismiss()
        if let displaced { onMeetingPromptDisplaced?(displaced) }
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
