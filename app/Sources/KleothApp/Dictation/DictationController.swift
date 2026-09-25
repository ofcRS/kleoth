import AppKit
import AVFoundation
import Foundation
import KleothCapture
import KleothCore
import KleothPillUI
import os

/// Owns a dictation session end to end: hotkey → capture → STT → polish →
/// insert → log → pill (design doc §2.3, §3.18, §5.10).
///
/// Internal, not `public`: it lives in an executable target where `public`
/// buys nothing. `@MainActor` because every collaborator it drives — the
/// `NSEvent` hotkey monitor, the `AVAudioEngine` capture, the pill panel, the
/// pasteboard inserter — is main-thread bound; the heavy work (audio prep,
/// network) is awaited from main-actor tasks, never run on it.
///
/// Every session exit funnels through `endSession()`: the two listening-exit
/// paths call it directly and the pipeline's single `defer` in `run()` calls
/// it on every other exit (success, early return, `.failed`, cancellation).
@MainActor
final class DictationController: ObservableObject {
    private(set) static var shared: DictationController?

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isTrusted: Bool
    @Published private(set) var isMonitoring: Bool {
        // The resting pill is the visible face of "armed": up exactly while
        // the hotkey monitors are running, gone when disabled/untrusted/quit.
        didSet { if isMonitoring != oldValue { updateResting() } }
    }
    @Published private(set) var dictationModel: String
    /// Mirrors `Settings.dictationPolishAlways` for the Settings toggle; the
    /// pipeline reads the fresh `AppConfig.settings()` value on every run.
    @Published private(set) var polishAlways: Bool
    /// Mirrors `Settings.dictationContext` for the Settings toggle; the wake,
    /// the snapshot at release and the pipeline read the fresh
    /// `AppConfig.settings()` value, as they read every other setting.
    @Published private(set) var contextEnabled: Bool
    /// True from `.began`/`.toggledOn` until `endSession()` (listening or pipeline in flight).
    @Published private(set) var isSessionActive: Bool = false
    /// Bumped AFTER `await logStore.append` returns (the row is on disk); DictationsListView reloads on change.
    @Published private(set) var logRevision: Int = 0
    /// The microphone pick — a CoreAudio device UID, nil for Automatic —
    /// mirrored for Settings and the pill menu. Meeting and screen recordings
    /// read the same value through `AppConfig.settings()`; the dictation
    /// capture is handed it at every chord-down / click.
    @Published private(set) var inputDeviceId: String?
    /// The pill menu's "Hide for 1 hour": the resting capsule stays off screen
    /// until this date. The hotkey keeps working — a session still rises, and
    /// sinks back into nothing. nil = not hidden.
    @Published private(set) var pillHiddenUntil: Date?
    /// Bumped by the pill menu's "Dictation history…". The History window
    /// opens (or comes forward) on the Dictations scope — the
    /// `RecordingController.meetingsHistoryRequest` idiom, because the pill is
    /// driven from a controller with no SwiftUI environment to open a window from.
    @Published private(set) var dictationsHistoryRequest: Int = 0
    /// Pending rows being transcribed right now — by the pill's Retry or from
    /// History. One run per row at a time; the History pane shows a spinner.
    @Published private(set) var busyPendingIds: Set<String> = []

    /// Rebound whenever Settings moves the output folder (`syncLogStore()`),
    /// so dictations never keep landing in — or being listed from — the old
    /// `~/Kleoth/dictations` after the user picks a new location.
    @Published private(set) var logStore: DictationLogStore
    /// False when a probe/test injected its own store: then it is never rebound.
    private let logStoreFollowsSettings: Bool

    private let monitor: any DictationHotkeyMonitoring
    private let pill: any DictationPillPresenting
    private let inserter: any TextInserting
    private let dictionary: PersonalDictionaryStore
    /// The STT seam. nil in production → `makeTranscriber(elevenLabsKey:)` builds a
    /// `ScribeClient` per run (the key can change in Settings between dictations).
    /// Injected by the `dictate` probe / tests.
    private let injectedTranscriber: (any Transcriber)?

    /// Bounded session: `URLSessionTransport.defaultSession` waits 1200 s
    /// between bytes. Scribe sends no byte while it transcribes, so both
    /// limits sit ABOVE the longest per-attempt budget
    /// (`DictationDefaults.scribeMaxBudget`) — that budget, not URLSession, is
    /// the timeout that fires. (At 30 s / 60 s these would have cut off the
    /// longer budgets before they ran out.)
    private let transport = URLSessionTransport(session: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = DictationDefaults.scribeMaxBudget + 10
        configuration.timeoutIntervalForResource = DictationDefaults.scribeMaxBudget + 30
        return URLSession(configuration: configuration)
    }())

    private let log = Logger(subsystem: "dev.kleoth", category: "Dictation")

    // MARK: Session state

    private enum Phase: Equatable {
        case idle
        case armed
        case listening(handsFree: Bool)
        case transcribing
        case polishing
        case inserting

        /// Steps 5–8 of the flow: a clip is committed and being processed.
        var isPipeline: Bool {
            switch self {
            case .transcribing, .polishing, .inserting: return true
            case .idle, .armed, .listening: return false
            }
        }
    }

    private var phase: Phase = .idle
    private let capture = DictationCapture()
    /// `for await event in monitor.events` — lives for the controller's lifetime
    /// (across Settings off→on cycles); only `shutdown()` cancels it.
    private var eventTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    /// The polish call in flight (a child of `pipelineTask`'s run), so Esc
    /// during `.polishing` can cancel JUST the model call and paste the raw
    /// transcript at once, instead of throwing the whole dictation away.
    /// Every path that cancels `pipelineTask` cancels this too
    /// (`cancelPipeline()`): an unstructured task does not inherit the cancel.
    private var polishTask: Task<DictationPolishResult, Never>?
    /// Set by `handleEscape()` when it cut a polish short — the result is then
    /// logged as skipped (no warning, no `polish_model`), not as a fallback.
    private var polishCancelledByUser = false
    /// Set by Esc while `.transcribing`: the run's cancellation path keeps
    /// the clip AND says so on the pill ("Stopped — saved to History").
    private var stopRequestedByEscape = false
    /// Set by `shutdown()`: a run cancelled on the way out keeps nothing — the
    /// process exits before an async keep could finish.
    private var isShuttingDown = false
    /// 20 Hz `capture.currentLevel` → `PillGeometry` → `pill.setLevel`.
    private var levelTask: Task<Void, Never>?
    /// Restores the pill's pipeline phase after the 1 s "Finishing the previous
    /// dictation…" refusal (a plain `.warning` would auto-hide the pill mid-run).
    private var refusalTask: Task<Void, Never>?
    /// Brings the resting pill back when "Hide for 1 hour" runs out.
    private var pillSnoozeTask: Task<Void, Never>?
    /// Every temp file the pipeline in flight owns, registered BEFORE it
    /// exists. `run()`'s `defer` empties it on every normal exit; it exists so
    /// `shutdown()` can delete the files SYNCHRONOUSLY — `pipelineTask.cancel()`
    /// only unblocks that `defer` on a later main-actor hop, which a
    /// terminating process never runs, and the launch sweep skips anything
    /// younger than an hour. Without it, quitting mid-pipeline left raw mic
    /// audio in `$TMPDIR/kleoth-dictation/` for the next hour.
    private var inFlightClips: [URL] = []
    /// The app that had focus at chord-down (prompt + log). Paste goes to
    /// whoever is frontmost at paste time — the inserter samples again.
    private var target: DictationTarget?
    /// Set when chord-down woke the target app's field (`wakeField(of:)`),
    /// so the session's end tells the reader to set back what it set.
    private var fieldWoken = false
    private var smoothedLevel: Double = 0

    private static let levelPollInterval: Duration = .milliseconds(50)
    private static let refusalDisplayDuration: Duration = .seconds(1)

    // MARK: - Init

    /// Production init (used by KleothApp.swift). Sets `shared`. `transcriber` nil → `ScribeClient`
    /// built per run from the current ElevenLabs key (see `makeTranscriber`).
    convenience init() {
        let settings = AppConfig.settings()
        self.init(
            monitor: DictationHotkeyMonitor(),
            // NOT a fresh `DictationPillController()`: there is one pill, and
            // `PillCoordinator` owns it so a screen recording's backdrop and a
            // dictation phase can share it (screen-recording design §3.4).
            pill: PillCoordinator.shared.dictationFace,
            inserter: TextInserter.shared,
            logStore: DictationLogStore(outputDir: settings.outputDir),
            dictionary: PersonalDictionaryStore(),
            transcriber: nil,
            logStoreFollowsSettings: true
        )
        Self.shared = self
    }

    /// Injected init (dictate probe / future tests). `transcriber` is THE seam the scope asks for:
    /// pass any `Transcriber` (a fake, or later `ScribeRealtimeTranscriber`) and `run()` uses it
    /// verbatim — cost logging reads `usdPerHour` from it.
    init(
        monitor: any DictationHotkeyMonitoring,
        pill: any DictationPillPresenting,
        inserter: any TextInserting,
        logStore: DictationLogStore,
        dictionary: PersonalDictionaryStore,
        transcriber: (any Transcriber)? = nil,
        logStoreFollowsSettings: Bool = false
    ) {
        let settings = AppConfig.settings()
        self.monitor = monitor
        self.pill = pill
        self.inserter = inserter
        self.logStore = logStore
        self.logStoreFollowsSettings = logStoreFollowsSettings
        self.dictionary = dictionary
        self.injectedTranscriber = transcriber
        self.isEnabled = settings.dictationEnabled
        self.isTrusted = AccessibilityPermission.isTrusted
        self.isMonitoring = false
        self.dictationModel = settings.dictationModel
        self.polishAlways = settings.dictationPolishAlways
        self.contextEnabled = settings.dictationContext
        self.inputDeviceId = settings.inputDeviceId

        pill.onAction = { [weak self] action in self?.handlePillAction(action) }
        pill.onDismiss = { [weak self] in self?.handlePillDismiss() }
        pill.menuContent = { [weak self] in self?.menuContent() ?? PillMenuContent() }
        // The monitor's 30 s health timer removes the monitors on its own when
        // trust is lost (bundle replaced by a rebuild); mirror that into the
        // published flags now, so the popover's "needs access" line appears
        // without waiting for the app to become active.
        monitor.onTrustLost = { [weak self] in self?.refreshTrust() }
    }

    /// Default engine factory; the only place `ScribeClient` is named in this file.
    private func makeTranscriber(elevenLabsKey: String) -> any Transcriber {
        ScribeClient(apiKey: elevenLabsKey, transport: transport)
    }

    // MARK: - Lifecycle

    /// AppDelegate.applicationDidFinishLaunching (via MainActor.assumeIsolated).
    func startIfEnabled() {
        DictationCapture.sweepStaleClips()
        sweepOrphanedAudio()
        ensureEventLoop()
        refreshTrust()
        guard isEnabled else { return }
        installMonitorIfPossible()
    }

    /// applicationWillTerminate: cancel(); monitor.stop(); eventTask?.cancel().
    /// Synchronous on purpose — the process may exit before any hop runs, which
    /// is also why the in-flight clips are deleted here rather than left to
    /// `run()`'s `defer`. A clip is kept only when a run fails or is stopped
    /// while the app keeps running; quitting mid-transcription discards it.
    func shutdown() {
        isShuttingDown = true
        cancel()
        pillSnoozeTask?.cancel()
        discardInFlightClips()
        monitor.stop()
        isMonitoring = false
        eventTask?.cancel()
        eventTask = nil
    }

    /// didBecomeActive + the Settings section's 1 Hz poll; reinstalls monitors on grant.
    /// Trust loss is handled by the monitor's own health timer (`stop()` → `.abort`),
    /// so this only has to mirror `isRunning` back into the published flag.
    func refreshTrust() {
        let trusted = AccessibilityPermission.isTrusted
        if isTrusted != trusted { isTrusted = trusted }
        if trusted, isEnabled, !monitor.isRunning {
            installMonitorIfPossible()
        }
        if isMonitoring != monitor.isRunning { isMonitoring = monitor.isRunning }
    }

    /// Esc / pill ✕ / external. Drops whatever is live: an armed or listening
    /// capture is cancelled (clip deleted), an in-flight pipeline is cancelled
    /// (its `defer` deletes the clips and resets the flags).
    ///
    /// Every exit here that the chord machine did not drive also calls
    /// `monitor.abort()`, so the machine and `phase` never disagree: without it
    /// a cancelled hands-free session leaves the machine parked in
    /// `.handsFree`, and the user's next fn+shift press is read as
    /// `.toggledOff` — swallowed by `finishListening()`'s guard, no pill, no
    /// mic. `.abort` emits `.cancelled(.external)`, which `handleCancelled`
    /// no-ops in every phase we can be in afterwards.
    func cancel() {
        refusalTask?.cancel()
        refusalTask = nil
        switch phase {
        case .idle:
            pill.dismiss()
        case .armed:
            capture.cancel()
            phase = .idle
            target = nil
            endFieldSession()
            armedDismissTask?.cancel()
            armedDismissTask = nil
            pill.dismiss()
        case .listening:
            capture.cancel()
            pill.dismiss()
            endSession()
            monitor.abort()
        case .transcribing, .polishing, .inserting:
            cancelPipeline()
            pill.dismiss()
            monitor.abort()
        }
    }

    /// Cancels the run in flight AND its polish child (see `polishTask`).
    private func cancelPipeline() {
        polishTask?.cancel()
        pipelineTask?.cancel()
    }

    // MARK: - Settings surface

    /// Keychain + (un)install; prompts for Accessibility when turning on untrusted.
    /// Asks for the History window on the Dictations scope. `KleothMenuBarLabel`
    /// opens the window and `HistoryView` flips its scope — both observe the
    /// counter; this is the one place it is bumped (pill menu, Settings).
    func requestDictationHistory() {
        HistoryRouting.requestedScope = .dictations
        dictationsHistoryRequest += 1
    }

    func setEnabled(_ on: Bool) {
        Keychain.set(on ? "true" : "false", Keychain.Account.dictationEnabled)
        isEnabled = on
        if on {
            ensureEventLoop()
            if !AccessibilityPermission.isTrusted {
                AccessibilityPermission.promptIfNeeded()
            }
            refreshTrust()
        } else {
            cancel()
            // `stop()` feeds `.abort` into the machine itself, so no separate `abort()`.
            monitor.stop()
            isMonitoring = false
        }
    }

    func setDictationModel(_ slug: String) {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? DictationDefaults.polishModel : DictationDefaults.migratingPolishModel(trimmed)
        Keychain.set(resolved, Keychain.Account.dictationModel)
        dictationModel = resolved
    }

    func setPolishAlways(_ on: Bool) {
        Keychain.set(on ? "true" : "false", Keychain.Account.dictationPolishAlways)
        polishAlways = on
    }

    /// "Use the text you're dictating into". The wake at chord-down and the
    /// read at release check it, so it takes effect from the next dictation;
    /// one already past its release keeps what it read.
    func setContextEnabled(_ on: Bool) {
        Keychain.set(on ? "true" : "false", Keychain.Account.dictationContext)
        contextEnabled = on
    }

    /// The microphone pick, from Settings or the pill menu. nil (or "") =
    /// Automatic. Takes effect on the next capture of any kind — a session in
    /// flight keeps its device.
    func setInputDevice(_ id: String?) {
        let resolved = id.flatMap { $0.isEmpty ? nil : $0 }
        // An explicit empty value is what lets "Automatic" win over a
        // `config.json` pick: the Keychain overlay reads empty as nil.
        Keychain.set(resolved ?? "", Keychain.Account.inputDevice)
        if inputDeviceId != resolved { inputDeviceId = resolved }
    }

    /// The pill menu's "Hide for 1 hour": the resting capsule is hidden until
    /// the hour is up; the hotkey and every session still work. The popover
    /// shows the deadline and offers `showPillNow()`, since the pill itself is
    /// gone and cannot offer it.
    func hidePill(for duration: Duration = .seconds(3600)) {
        pillSnoozeTask?.cancel()
        pillHiddenUntil = Date().addingTimeInterval(TimeInterval(duration.components.seconds))
        updateResting()
        pillSnoozeTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            self.pillSnoozeTask = nil
            self.pillHiddenUntil = nil
            self.updateResting()
        }
    }

    func showPillNow() {
        guard pillHiddenUntil != nil else { return }
        pillSnoozeTask?.cancel()
        pillSnoozeTask = nil
        pillHiddenUntil = nil
        updateResting()
    }

    /// The resting capsule is up exactly while the hotkey monitors run AND
    /// the user has not hidden it for the hour.
    private func updateResting() {
        pill.setResting(isMonitoring && pillHiddenUntil == nil)
    }

    /// promptIfNeeded + refreshTrust.
    func requestAccessibility() {
        AccessibilityPermission.promptIfNeeded()
        refreshTrust()
    }

    func resetPillPosition() {
        pill.resetPosition()
    }

    // MARK: - Dictionary + log surfaces (views touch one object)

    func dictionaryTerms() -> [String] {
        dictionary.load()
    }

    func saveDictionaryTerms(_ terms: [String]) {
        do {
            try dictionary.save(terms)
        } catch {
            log.error("dictionary save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Sync: nonisolated store reads.
    func loadDictations(limit: Int = 500) -> [DictationLogEntry] {
        syncLogStore()
        return logStore.loadAll(limit: limit)
    }

    /// Hops to the store actor; bumps logRevision — even on failure, since
    /// `delete` walks day files one at a time and a throw partway leaves
    /// earlier days already rewritten (the list must reload to what is on disk).
    ///
    /// A pending row's kept clip follows it to the Trash (read before the rows
    /// go, in one pass over the day files, off the main actor). A clip the
    /// Trash refuses stays put for the launch sweep — never erased outright,
    /// since the confirmation promised the Trash. A row being transcribed
    /// right now is left alone (History disables Delete for it; this is the
    /// backstop for a pill Retry that started meanwhile).
    func deleteDictations(ids: Set<String>) async throws {
        syncLogStore()
        defer { logRevision += 1 }
        let ids = ids.subtracting(busyPendingIds)
        guard !ids.isEmpty else { return }
        let store = logStore
        let keptFiles = await Task.detached(priority: .userInitiated) {
            store.loadAll(limit: Int.max)
                .filter { ids.contains($0.id) }
                .compactMap(\.audioFileName)
        }.value
        _ = try await logStore.delete(ids: ids)
        let audio = audioStore
        for name in keptFiles {
            audio.trash(fileNamed: name)
        }
    }

    /// Rebinds `logStore` if Settings moved the output folder since the last
    /// use. `RecordingController` mutates `outputDir` live; every other config
    /// value the pipeline needs is re-read per run, and this keeps the store
    /// from being the one stale binding. Cheap: `AppConfig.settings()` reads
    /// the in-memory Keychain cache.
    private func syncLogStore(to settings: Settings? = nil) {
        guard logStoreFollowsSettings else { return }
        let outputDir = (settings ?? AppConfig.settings()).outputDir
        let expected = DictationLogStore(outputDir: outputDir)
        guard expected.baseDir.standardizedFileURL != logStore.baseDir.standardizedFileURL else { return }
        log.notice("dictation log store rebound to \(expected.baseDir.path, privacy: .public)")
        logStore = expected
    }

    // MARK: - Monitor plumbing

    private func installMonitorIfPossible() {
        guard isEnabled else { return }
        ensureEventLoop()
        let running = monitor.isRunning || monitor.start()
        if isMonitoring != running { isMonitoring = running }
        if !running {
            log.notice("hotkey monitor not installed (Accessibility not trusted)")
        }
    }

    /// One consumer of `monitor.events` for the controller's lifetime. The stream
    /// is never finished by the monitor; `AsyncStream` iteration returns nil when
    /// this task is cancelled (`shutdown()`).
    private func ensureEventLoop() {
        guard eventTask == nil else { return }
        let events = monitor.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    // MARK: - Hotkey events (§2.3 controller table)

    private func handle(_ event: DictationHotkeyEvent) {
        log.debug("event \(String(describing: event), privacy: .public) in phase \(String(describing: self.phase), privacy: .public)")
        switch event {
        case .armed:
            handleArmed()
        case .began:
            beginListening(handsFree: false)
        case .toggledOn:
            beginListening(handsFree: true)
        case .latched:
            switchToHandsFree()
        case .ended, .toggledOff:
            finishListening()
        case .cancelled(let reason):
            handleCancelled(reason)
        case .escapePressed:
            handleEscape()
        }
    }

    /// Chord down: preflight, sample the target, mic on — NO UI yet (a tap
    /// under `minHold` may still be discarded).
    private func handleArmed() {
        switch phase {
        case .idle:
            break
        case .transcribing, .polishing, .inserting:
            refuseWhileBusy()
            return
        case .armed, .listening:
            return   // the machine never re-arms while capturing; belt and braces
        }

        guard preflight() else { return }

        target = DictationTarget.frontmost()
        // Acknowledge the press on its first frame, BEFORE the mic opens: the
        // resting capsule hops out of its edge (no words, no bars).
        // `DictationCapture.start()` now builds a fresh engine per session
        // (~200 ms on a Bluetooth headset — see its type comment) and the hop
        // must not wait for it. `.listening` grows out of it at `minHold`; a
        // discarded tap sinks it back (`handleCancelled`); a start failure
        // replaces it with the `.failed` pill below.
        armedDismissTask?.cancel()
        armedDismissTask = nil
        pill.show(.armed)
        // Before the mic too: the target app builds its accessibility tree
        // while the user speaks (§3.2).
        wakeField(of: target)
        capture.inputDeviceId = inputDeviceId
        do {
            try capture.start()
        } catch {
            target = nil
            endFieldSession()
            log.error("dictation capture failed to start: \(error.localizedDescription, privacy: .public)")
            pill.show(.failed(.message(error.localizedDescription)))
            return
        }
        phase = .armed
    }

    /// The gates every session passes before the mic opens, in order: enabled
    /// → Accessibility → ElevenLabs key → microphone not denied → no secure
    /// input. Each failure is a sticky `.failed` pill (no spend, no log row)
    /// and false. Shared by chord-down and the pill's Dictate click.
    private func preflight() -> Bool {
        guard isEnabled else { return false }
        guard AccessibilityPermission.isTrusted else {
            isTrusted = false
            pill.show(.failed(.needsAccessibility))
            return false
        }
        let credentials = AppConfig.credentials()
        guard let key = credentials.elevenLabsKey, !key.isEmpty else {
            pill.show(.failed(.missingElevenLabsKey))
            return false
        }
        guard RecordingController.microphoneStatus() != .denied else {
            pill.show(.failed(.message(DictationError.microphoneDenied.errorDescription ?? "Kleoth needs microphone access.")))
            return false
        }
        guard !InsertionEnvironment.isSecureInputActive else {
            let holder = InsertionEnvironment.secureInputHolder
            log.info("Dictation refused: secure input held by \(holder?.bundleIdentifier ?? "unknown", privacy: .public)")
            pill.show(.failed(.secureInput(holder: holder?.localizedName)))
            return false
        }
        return true
    }

    /// Set by a too-short tap: the armed capsule stays out for the double-tap
    /// window, so a hands-free double-tap does not see it sink and rise again.
    private var armedDismissTask: Task<Void, Never>?

    /// `.began` (push-to-talk confirmed) / `.toggledOn` (hands-free): the pill appears.
    private func beginListening(handsFree: Bool) {
        guard phase == .armed else { return }
        armedDismissTask?.cancel()
        armedDismissTask = nil
        phase = .listening(handsFree: handsFree)
        monitor.escapeCancels = true
        isSessionActive = true
        pill.show(.listening(handsFree: handsFree))
        startLevelPoll()
    }

    /// When the last push-to-talk went hands-free, for the double-click guard
    /// in `stopHandsFreeFromPill()`. Cleared by `endSession()`.
    private var latchedAt: ContinuousClock.Instant?

    /// `.latched`: a held push-to-talk goes hands-free (⌘ joined the chord, or
    /// the click on the capsule). The capture and the level poll run on
    /// untouched — the words already spoken stay in the same clip — only the
    /// phase and the pill change.
    ///
    /// The machine latches only from a confirmed hold, so it is normally in
    /// step with `.listening(handsFree: false)`. Already hands-free, machine
    /// and phase agree and there is nothing to do. Anywhere else (the capture
    /// failed at chord-down, so `.began` found no `.armed` session) the
    /// machine is now parked hands-free over nothing and would eat the next
    /// press as `.toggledOff`: abort it back to idle instead.
    private func switchToHandsFree() {
        switch phase {
        case .listening(handsFree: false):
            break
        case .listening(handsFree: true):
            return
        case .idle, .armed, .transcribing, .polishing, .inserting:
            monitor.abort()
            return
        }
        phase = .listening(handsFree: true)
        latchedAt = .now
        pill.show(.listening(handsFree: true))
    }

    /// `.ended` / `.toggledOff`: commit the clip (or drop it when too short).
    private func finishListening() {
        guard case .listening = phase else { return }
        stopLevelPoll()

        let clip: DictationCaptureResult?
        do {
            clip = try capture.stop(minimumSeconds: DictationDefaults.minimumUtterance)
        } catch {
            // `.writeFailed` with zero frames: the stream died under us.
            pill.show(.failed(.message("The microphone stream was interrupted.")))
            endSession()
            return
        }
        guard let clip else {
            pill.dismiss()
            endSession()
            return
        }

        phase = .transcribing
        let pressTimeTarget = target
        // The field is read now, alongside the audio preparation and the
        // upload, and awaited only at the polish step (§3.2).
        let field = readField(of: pressTimeTarget)
        pipelineTask = Task { [weak self] in
            await self?.run(clip: clip, target: pressTimeTarget, field: field)
        }
    }

    private func handleCancelled(_ reason: DictationHotkeyEvent.CancelReason) {
        switch phase {
        case .armed:
            capture.cancel()
            phase = .idle
            target = nil
            endFieldSession()
            armedDismissTask?.cancel()
            if reason == .tooShort {
                // May still become a double-tap: hold the peeked capsule
                // through the window, then sink it.
                armedDismissTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(DictationDefaults.doubleTapWindow))
                    guard !Task.isCancelled, let self, self.phase == .idle else { return }
                    self.armedDismissTask = nil
                    self.pill.dismiss()
                }
            } else {
                armedDismissTask = nil
                pill.dismiss()
            }
        case .listening:
            capture.cancel()
            pill.dismiss()
            endSession()
        case .idle, .transcribing, .polishing, .inserting:
            // A `.cancelled(.external)` from `monitor.stop()` mid-pipeline is
            // deliberate no-op: the committed speech still lands (or falls back
            // to the clipboard if trust really is gone). `setEnabled(false)`
            // cancels explicitly via `cancel()`.
            break
        }
    }

    /// `.escapePressed` only arrives while the chord is UP, so the listening
    /// case is hands-free (push-to-talk Esc reaches the machine as
    /// `.otherKey` instead): the machine sits in `.handsFree` and must be
    /// aborted back to idle, or the next press would be a `.toggledOff`.
    private func handleEscape() {
        switch phase {
        case .listening:
            capture.cancel()
            pill.dismiss()
            endSession()
            monitor.abort()
        case .polishing:
            // "I have waited long enough": drop the model call, paste the raw
            // transcript now. The run continues into `.inserting`, so the pill
            // stays up and ends in `.done`.
            polishCancelledByUser = true
            polishTask?.cancel()
        case .transcribing:
            // "Stop waiting" — the words were already spoken. The run's
            // cancellation path keeps the clip and says where it went
            // ("Stopped — saved to History"), so the pill is left for it to
            // settle (at most the preparation step's second or two later).
            stopRequestedByEscape = true
            cancelPipeline()
        case .inserting:
            cancelPipeline()
            pill.dismiss()
        case .idle, .armed:
            break
        }
    }

    /// The ONLY place the session flags go back down (§2.3).
    private func endSession() {
        phase = .idle
        latchedAt = nil
        monitor.escapeCancels = false
        isSessionActive = false
        stopLevelPoll()
        target = nil
        endFieldSession()
    }

    /// A chord press while steps 5–8 are in flight: refuse, but say so. The
    /// warning is shown for 1 s and then the phase's own pill state returns —
    /// a bare `.warning` would auto-hide the pill after 3 s while the pipeline
    /// is still running.
    ///
    /// The machine is aborted while the refused chord is still down, so the
    /// release is swallowed and no tap window opens. Without this a refused
    /// double-tap would walk the machine `tapWindow → handsFreeArming →
    /// handsFree` behind the controller's back, and the first press after the
    /// pipeline settled would be eaten as `.toggledOff`. The abort emits
    /// `.cancelled(.external)`, a no-op in every pipeline phase (and in idle).
    private func refuseWhileBusy() {
        monitor.abort()
        refusalTask?.cancel()
        pill.show(.warning("Finishing the previous dictation…"))
        refusalTask = Task { [weak self] in
            try? await Task.sleep(for: Self.refusalDisplayDuration)
            guard !Task.isCancelled, let self, self.phase.isPipeline else { return }
            self.pill.show(self.pillState(for: self.phase))
            self.refusalTask = nil
        }
    }

    private func pillState(for phase: Phase) -> DictationPillState {
        switch phase {
        case .transcribing: return .transcribing
        case .polishing, .inserting: return .polishing
        case .listening(let handsFree): return .listening(handsFree: handsFree)
        case .idle, .armed: return .hidden
        }
    }

    // MARK: - Level meter

    private func startLevelPoll() {
        stopLevelPoll()
        smoothedLevel = 0
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.levelPollInterval)
                guard !Task.isCancelled, let self else { return }
                let target = PillGeometry.normalizedLevel(rms: self.capture.currentLevel)
                self.smoothedLevel = PillGeometry.smoothLevel(previous: self.smoothedLevel, target: target)
                self.pill.setLevel(self.smoothedLevel)
            }
        }
    }

    private func stopLevelPoll() {
        levelTask?.cancel()
        levelTask = nil
        smoothedLevel = 0
    }

    // MARK: - Pipeline (steps 5–10)

    /// What steps 6–10 run on: a fresh clip, or a kept one the pill's Retry
    /// sends again (dictation-retry design §3.3).
    private struct SessionJob {
        /// The file to transcribe: the prepared clip, or — when preparing it
        /// failed — the raw one (Scribe takes it as it is).
        var audio: URL
        var durationSeconds: Double
        /// A device switch cut the capture short (fresh clips only).
        var interrupted: Bool
        /// The pending row this run retries; nil for a fresh clip.
        var pending: DictationLogEntry?
        /// The app the dictation was made in, for the polish prompt and the
        /// log row. The paste goes to whoever is frontmost at paste time.
        var target: DictationTarget?
        /// The focused field's read, started at release (`readField(of:)`).
        /// nil when nothing was read: the setting is off, another app was in
        /// front at release, and always for the pill's Retry, whose words were
        /// spoken earlier, maybe elsewhere (§3.2).
        var field: Task<FieldRead, Never>? = nil
        /// When the clip was committed — a pending row is stamped with this,
        /// not with the moment two long attempts later that it was kept.
        var startedAt = Date()
    }

    /// The focused field as read at release: the reader's snapshot, and the
    /// row's `context_seconds`.
    ///
    /// `FocusedTextReader.Snapshot` alone can't say how long a read took that
    /// found nothing or was abandoned, and §5 stores the budget for a read that
    /// timed out.
    private struct FieldRead: Sendable {
        /// nil when the read found nothing to classify, or was abandoned.
        var snapshot: FocusedTextReader.Snapshot?
        /// The snapshot's own seconds; the read budget when it was abandoned;
        /// the time the call took when it found nothing.
        var seconds: Double
    }

    /// A polish result and what it took: the seconds (when a model ran) and
    /// the provider + model it resolved to, so the log row records what
    /// actually ran.
    private struct PolishOutcome {
        var result: DictationPolishResult
        var seconds: Double? = nil
        var selection: ProviderFactory.Selection? = nil
        /// The field context the paste follows (`DictationInsertionPlan`):
        /// the policy's, with a merge turned into an append once the resolved
        /// provider turns out to take no field context. nil = none.
        var field: DictationFieldContext? = nil
    }

    /// Step 5 (prepare), then steps 6–10 in `runSession`. Temp files are
    /// registered in `inFlightClips` as they are named, so the single `defer`
    /// (and a synchronous `shutdown()`) can delete every one of them — except
    /// a clip `keep(_:reason:)` moved into the kept-audio folder, which it
    /// takes off the list first. The `defer` also owns every flag reset
    /// (`finishPipeline()` → `endSession()`), so every exit — success, early
    /// return, `.failed`, cancellation — tears down the same way.
    private func run(
        clip: DictationCaptureResult, target: DictationTarget?, field: Task<FieldRead, Never>?
    ) async {
        inFlightClips = [clip.fileURL]
        defer {
            discardInFlightClips()
            finishPipeline()
        }

        let credentials = AppConfig.credentials()
        let settings = AppConfig.settings()
        syncLogStore(to: settings)
        guard let key = credentials.elevenLabsKey, !key.isEmpty else {
            pill.show(.failed(.missingElevenLabsKey))   // also checked at `armed`
            return
        }

        var job = SessionJob(
            audio: clip.fileURL,
            durationSeconds: clip.durationSeconds,
            interrupted: clip.interrupted,
            pending: nil,
            target: target,
            field: field
        )

        // 5. Prepare (off-main): mono downmix + loudness/peak normalize, 64 kbps.
        //    The destination is named — and registered for deletion — here, so a
        //    quit *during* the preparation can't strand a half-written clip. A
        //    failure keeps the RAW clip (`job.audio` still points at it).
        let raw = clip.fileURL
        let destination = DictationCapture.preparedURL(for: raw)
        inFlightClips.append(destination)
        do {
            job.audio = try await Task.detached(priority: .userInitiated) {
                try DictationCapture.prepareForUpload(raw, outputURL: destination)
            }.value
        } catch {
            if Task.isCancelled {
                await settleCancelledRun(job)
            } else {
                log.error("audio preparation failed: \(String(describing: error), privacy: .public)")
                let message = "Couldn't prepare the audio (\(error.localizedDescription))."
                await settleFailedRun(
                    job,
                    summary: DictationTranscription.Summary(cause: "Couldn't prepare the audio", detail: message),
                    fallback: message
                )
            }
            return
        }
        // `.value` on a detached task does not propagate our cancellation.
        guard !Task.isCancelled else {
            await settleCancelledRun(job)
            return
        }

        await runSession(job, key: key, settings: settings)
    }

    /// The teardown every pipeline exit shares — a fresh clip's run and the
    /// pill's Retry. `endSession()` also ends the reader's session
    /// (`endFieldSession()`), setting back any wake attribute it set.
    private func finishPipeline() {
        refusalTask?.cancel()
        refusalTask = nil
        pipelineTask = nil
        stopRequestedByEscape = false
        endSession()
    }

    /// Steps 6–10 of a live session — a fresh clip, or the pill's Retry of a
    /// kept one: transcribe → polish → paste → log → settle. Scribe runs
    /// under `DictationTranscription`'s policy (a budget that grows with the
    /// clip, one retry after a transient failure); a run that ends without a
    /// transcript keeps the clip (`settleFailedRun` / `settleCancelledRun`).
    private func runSession(_ job: SessionJob, key: String, settings: Settings) async {
        // Resolving the polisher can cost the provider probes (CLI `auth
        // status`, the local server) whenever the detector's cache is cold, so
        // it runs ALONGSIDE the upload instead of after it — by the time step 7
        // awaits the task, the answer is almost always already there.
        //
        // It is deliberately NOT cancelled on the early exits below (Esc, an
        // STT failure, an empty transcript, a PolishGate skip). Cancelling it
        // would terminate the probes mid-flight, and each one reports a
        // killed child / cancelled request as a negative verdict — so the
        // orphan is left to finish and warm the detector's cache for the next
        // dictation. It costs nothing user-visible: the probes bound
        // themselves at 10 s each and the task touches no session state.
        let polisherTask = Task { try await AppConfig.makePolisher() }
        polishCancelledByUser = false

        // 6. Transcribe through the `Transcriber` seam.
        let terms = Keyterms.sanitize(dictionary.load())
        let options = ScribeOptions.dictation(keyterms: terms)
        let transcriber: any Transcriber = injectedTranscriber ?? makeTranscriber(elevenLabsKey: key)
        pill.show(.transcribing)
        let transcription: DictationTranscription.Result
        do {
            transcription = try await DictationTranscription.run(
                transcriber,
                fileURL: job.audio,
                options: options,
                policy: .scribe(audioSeconds: job.durationSeconds),
                onAttemptFailed: Self.logFailedAttempt
            )
        } catch let failure as DictationTranscription.Failure {
            // The full error (a Scribe HTTP body can be 512 bytes of JSON)
            // belongs in the log; the pill gets the short form.
            log.error("transcription failed: \(String(describing: failure), privacy: .public)")
            await settleFailedRun(
                job,
                summary: DictationTranscription.summary(of: failure, attempts: failure.attempts),
                fallback: Self.userFacing(failure.underlying)
            )
            return
        } catch {
            // `run` throws nothing else: Esc, dictation turned off, or quit.
            await settleCancelledRun(job)
            return
        }
        let rawText = Self.extractText(transcription.response)
        guard !rawText.isEmpty else {
            if let pending = job.pending {
                // A kept clip with no speech in it. The row stays — the user
                // decides in History — with the reason brought up to date.
                await recordFailure(on: pending, reason: "No speech was found in the audio.")
                pill.show(.warning("Nothing was heard — the audio is still in History"))
            } else {
                // Silence is not an error: the pill just sinks back to resting,
                // exactly like a too-short hold. No warning, no log row.
                log.debug("transcript empty — nothing to paste")
                pill.dismiss()
            }
            return
        }

        // 7. The field read at release, then the polish (non-throwing; raw
        // fallback built in) — unless the gate says Scribe's text is already
        // what the user wants (`polish(…)`). The read started at release under
        // its own budget, so it is almost always done by now. It exists only
        // when the press-time app was still in front at release
        // (`readField(of:)`); the row keeps the press-time app either way.
        let fieldRead = await job.field?.value
        let field = fieldRead?.snapshot.flatMap { DictationContextPolicy.context(from: $0.facts, kind: $0.kind) }
        if let field {
            log.info("Context: \(Self.describe(field), privacy: .public)")
        }
        let context = DictationContext(
            appBundleId: job.target?.bundleIdentifier,
            appName: job.target?.localizedName,
            languageCode: transcription.response.languageCode,
            dictionary: terms
        )
        let polish = await polish(
            rawText, context: context, field: field, settings: settings, polisherTask: polisherTask,
            interactive: true
        )
        // The whole run cancelled during the polish call (not Esc, which
        // cancels only the model call): the polisher swallows cancellation
        // into a `.raw` result, so check here before anything reaches the
        // pasteboard.
        guard !Task.isCancelled else {
            pill.dismiss()
            return
        }

        // 8. Re-check the field, plan the paste, insert. The plan decides what
        // ⌘V pastes over a selection or at a caret (§3.3–§3.5); without field
        // context it is the polish result as it is, exactly as before.
        phase = .inserting
        let recheck = await recheckField(fieldRead?.snapshot, for: polish.field)
        // Esc (or any cancel) during the re-check: the run ends here, as it
        // does when cancelled during the polish — nothing reaches the
        // pasteboard, and the pill goes away with no `.failed` state.
        guard !Task.isCancelled else {
            pill.dismiss()
            return
        }
        let plan = DictationInsertionPlan.decide(
            context: polish.field, polish: polish.result, rawText: rawText, recheck: recheck
        )
        if let outcome = plan.outcome {
            log.info("Context paste: \(outcome.rawValue, privacy: .public), \(plan.text.count) characters")
        }
        var method = DictationInsertMethod.paste
        // The pill's warning, most important first: the clipboard fallback
        // below (actionable: "press ⌘V"); what happened to the selection (the
        // plan's — it matters more than why the polish fell back; the row keeps
        // the polish's reason, except a `selection_changed` row, which keeps the
        // plan's warning instead); a polish fallback (the text isn't what was
        // said either); a device switch mid-utterance that quiesced the mic
        // early (§7) — the clip is still worth pasting, but the pill has to say
        // it is partial instead of letting a truncated sentence look finished.
        var warning = plan.warning
            ?? polish.result.fallbackReason
            ?? (job.interrupted ? "The microphone changed mid-dictation — only part was captured." : nil)
        do {
            try await inserter.insert(plan.text, pressTimeTarget: job.target ?? .frontmost())
        } catch let insertion as TextInsertionError where insertion.textLeftOnClipboard {
            method = .clipboard
            warning = insertion.errorDescription
        } catch {
            pill.show(.failed(.message(error.localizedDescription)))
            return
        }

        // 9. Log (actor-serialized, off-main) — a new row, or the kept row
        //    filled in — then bump the revision.
        let entry = makeEntry(
            pending: job.pending,
            durationSeconds: job.durationSeconds,
            transcription: transcription,
            transcriber: transcriber,
            options: options,
            terms: terms,
            rawText: rawText,
            polish: polish,
            context: context,
            method: method,
            plan: plan,
            contextSeconds: fieldRead?.seconds
        )
        await persist(entry, resolving: job.pending)

        // 10. Settle.
        pill.show(warning.map { .warning($0) } ?? .done)
    }

    /// Step 7, shared by a live session and a History run: skip (the gate
    /// says Scribe's text is already what the user wants — a message into a
    /// chat app, or a short utterance), polish, or fall back to the raw text
    /// with a reason. Never throws. Skipping is not a fallback: no warning,
    /// no `polish_model` on the row, and no polishing wave on the pill.
    ///
    /// `interactive` is a live session: once the gate says polish, the session
    /// is `.polishing` — BEFORE the polisher is resolved, so Esc in that wait
    /// (seconds when the provider cache is cold) already means "paste it as
    /// heard" rather than cancelling a dictation whose words are in hand — and
    /// Esc during the model call cuts it short (`polishTask`). A History run
    /// passes false and touches no session state.
    ///
    /// `field` is the policy's context for the focused field (nil for a
    /// History run, or when nothing was read). The gate sees it before any
    /// provider is resolved (a merge always polishes; a caret mid-sentence
    /// does in a compose app). Once the provider is known, the polisher gets
    /// the context that provider takes, and the outcome carries the one the
    /// paste follows (`PolishOutcome.field`). Esc always comes back as
    /// `.skipped`, never as the polisher's `.raw(…, "Cancelled.")`: a merge
    /// cut short then goes in as the selection plus the dictation with no
    /// warning, the Esc rule (§5).
    private func polish(
        _ rawText: String,
        context: DictationContext,
        field: DictationFieldContext?,
        settings: Settings,
        polisherTask: Task<(DictationPolisher, ProviderFactory.Selection), any Error>,
        interactive: Bool
    ) async -> PolishOutcome {
        let gate = PolishGate.decide(
            rawText: rawText,
            style: AppStyle.classify(bundleId: context.appBundleId),
            alwaysPolish: settings.dictationPolishAlways,
            placement: PolishGate.placement(for: field)
        )
        if case let .skip(reason) = gate {
            log.debug("polish skipped: \(reason, privacy: .public)")
            return PolishOutcome(result: .skipped(text: rawText, reason: reason), field: field)
        }
        if interactive {
            phase = .polishing
            pill.show(.polishing)
        }
        do {
            // Resolved alongside the upload (step 6), so this normally
            // returns at once; only a cold detector cache makes it wait.
            let (polisher, selection) = try await polisherTask.value
            // Only some providers take the field (§3.1). One that doesn't
            // polishes the dictation alone, so a selection can't be merged:
            // it goes back with the dictation after it, and the pill says why.
            let provider = selection.provider
            var context = context
            context.field = field?.promptContext(providerSupportsContext: provider.supportsDictationContext)
            let pasteField = provider.supportsDictationContext
                ? field
                : field?.appendingInstead(because: "\(provider.displayName) can't merge — added the dictation after the selection")
            if interactive, polishCancelledByUser {
                // Esc while the model was still being picked.
                return PolishOutcome(
                    result: .skipped(text: rawText, reason: "Cancelled with Esc — pasted as heard."), field: pasteField
                )
            }
            // Its own task so Esc can cancel the model call alone
            // (`handleEscape`); `cancelPipeline()` cancels both together.
            let started = ContinuousClock.now
            let task = Task { await polisher.polish(rawText: rawText, context: context) }
            if interactive { polishTask = task }
            let attempted = await task.value
            if interactive { polishTask = nil }
            let elapsed = started.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            // A polisher sent no field ends a fallback reason with today's
            // consequence; the paste may do otherwise (an appended selection),
            // and the row's reason says what it did.
            let reworded = provider.supportsDictationContext
                ? attempted
                : Self.fallback(attempted, endingWith: pasteField?.fallbackConsequence)
            let result: DictationPolishResult = (interactive && polishCancelledByUser)
                ? .skipped(text: rawText, reason: "Cancelled with Esc — pasted as heard.")
                : reworded
            log.debug("polish \(result.ranModel ? "ok" : (result.usedRawFallback ? "fallback" : "skipped"), privacy: .public) in \(seconds, format: .fixed(precision: 2)) s")
            return PolishOutcome(result: result, seconds: seconds, selection: selection, field: pasteField)
        } catch {
            // No backend could be built. `ProviderError`'s copy is a full
            // sentence, so drop its final period before the suffix turns the
            // whole line into one. The suffix says what the paste does
            // instead: a selection being merged gets the raw dictation after
            // it (the plan appends, since the polish is `.raw`).
            let consequence = field?.fallbackConsequence ?? "pasted the raw transcript."
            return PolishOutcome(
                result: .raw(text: rawText, reason: "\(Self.asClause(error.localizedDescription)) — \(consequence)"),
                field: field
            )
        }
    }

    /// The row a transcribed run logs: a new one, or the kept row filled in —
    /// same id and timestamp, its audio and error cleared.
    ///
    /// `plan` and `contextSeconds` are a live session's field context (§3.1):
    /// how it was used (`field_context`), the selection a merge replaced
    /// (`replaced_text`) and how long the read at release took. A History run
    /// and the pill's Retry read no field and pass neither, so all three stay
    /// nil. `polished_text` is the polish result — the merged piece, or the
    /// dictation alone — never the selection an append put back around it;
    /// after a selection that changed, it is the dictation as heard.
    private func makeEntry(
        pending: DictationLogEntry?,
        durationSeconds: Double,
        transcription: DictationTranscription.Result,
        transcriber: any Transcriber,
        options: ScribeOptions,
        terms: [String],
        rawText: String,
        polish: PolishOutcome,
        context: DictationContext,
        method: DictationInsertMethod,
        plan: DictationInsertionPlan? = nil,
        contextSeconds: Double? = nil
    ) -> DictationLogEntry {
        let surcharge = terms.isEmpty ? 1 : DictationDefaults.keytermSurchargeMultiplier
        let ranModel = polish.result.ranModel
        var polishedText = polish.result.text
        var usedRawFallback = polish.result.usedRawFallback
        var fallbackReason = polish.result.fallbackReason
        if let plan, plan.outcome == .selectionChanged {
            // ⌘V pasted the dictation alone, as heard (R6), so the row is a
            // raw-fallback row: `polished_text` == `raw_text`, with the plan's
            // warning as the reason. Never the model's merge: it holds the old
            // selection, which "Paste last dictation" or Copy would put
            // somewhere else — the duplication the paste avoided — and which is
            // stored nowhere but `replaced_text`. Nor the paste's fitted
            // spacing, which belonged to that caret. The model still ran: its
            // model, provider and cost stay.
            polishedText = rawText
            usedRawFallback = true
            fallbackReason = plan.warning
        }
        return DictationLogEntry(
            id: pending?.id ?? UUID().uuidString,
            timestamp: pending?.timestamp ?? DictationLogEntry.isoTimestamp(Date()),
            appBundleId: context.appBundleId,
            appName: context.appName,
            language: transcription.response.languageCode,              // the engine's code wins on disk
            rawText: rawText,
            polishedText: polishedText,
            usedRawFallback: usedRawFallback,
            fallbackReason: fallbackReason,
            transcriptionModel: transcriber.modelIdentifier(for: options),   // what actually ran
            polishModel: ranModel ? polish.selection?.model : nil,
            polishProvider: ranModel ? polish.selection?.provider.rawValue : nil,
            durationSeconds: durationSeconds,
            insertMethod: method,
            transcriptionCost: transcriber.usdPerHour * durationSeconds / 3600 * surcharge,
            polishCost: polish.result.cost,
            polishSeconds: polish.seconds,
            transcriptionSeconds: transcription.seconds,
            fieldContext: plan?.outcome?.rawValue,
            replacedText: plan?.replacedText,
            contextSeconds: contextSeconds
        )
    }

    /// Step 9's write: append a new row, or rewrite the kept row in place and
    /// delete its clip (only once the row is on disk). A kept row deleted in
    /// History mid-run is logged as a new row — the text did land somewhere.
    private func persist(_ entry: DictationLogEntry, resolving pending: DictationLogEntry?) async {
        do {
            if let pending {
                let replaced = try await logStore.replace(entry)
                if !replaced {
                    try await logStore.append(entry)
                }
                if let name = pending.audioFileName {
                    audioStore.remove(fileNamed: name)
                }
            } else {
                try await logStore.append(entry)
            }
        } catch {
            log.error("dictation log write failed: \(error.localizedDescription, privacy: .public)")
        }
        logRevision += 1   // AFTER the row is on disk
    }

    /// `DictationTranscription.run`'s per-attempt report, into the unified log.
    private static let logFailedAttempt: @Sendable (Int, any Error, TimeInterval) -> Void = { attempt, error, seconds in
        Logger(subsystem: "dev.kleoth", category: "Dictation").error(
            "transcription attempt \(attempt) failed after \(seconds, format: .fixed(precision: 1)) s: \(String(describing: error), privacy: .public)"
        )
    }

    /// `result` with a fallback reason's closing "pasted the raw transcript."
    /// replaced by `consequence` — what the paste does instead when the
    /// polisher was sent no field but the paste follows one (a provider that
    /// can't merge: "added the dictation after the selection."). Anything
    /// else comes back as it was.
    private static func fallback(_ result: DictationPolishResult, endingWith consequence: String?) -> DictationPolishResult {
        let today = "pasted the raw transcript."
        guard let consequence, consequence != today,
              case let .raw(text, reason, cost) = result, reason.hasSuffix(today)
        else { return result }
        return .raw(text: text, reason: String(reason.dropLast(today.count)) + consequence, cost: cost)
    }

    /// A finished sentence turned into a clause, so appending
    /// " — pasted the raw transcript." does not leave a stray period mid-line.
    private static func asClause(_ sentence: String) -> String {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
    }

    /// Deletes every temp file the current run registered. Idempotent
    /// (`DictationCapture.discard` ignores "already gone"), so the `defer` and
    /// `shutdown()` can both call it.
    private func discardInFlightClips() {
        for url in inFlightClips {
            DictationCapture.discard(url)
        }
        inFlightClips.removeAll()
    }

    /// Dictation responses are single-channel and undiarized, so `text` is the
    /// whole transcript; the fallbacks cover a `Transcriber` that only fills
    /// `words` or `transcripts`.
    private static func extractText(_ response: ScribeResponse) -> String {
        if let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        if let words = response.words, !words.isEmpty {
            let joined = words
                .filter { $0.type != "audio_event" }
                .map(\.text)
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { return joined }
        }
        if let transcripts = response.transcripts {
            let joined = transcripts
                .compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !joined.isEmpty { return joined }
        }
        return ""
    }

    /// `ScribeError` is `CustomStringConvertible`, NOT `LocalizedError` — its
    /// `localizedDescription` is "The operation couldn't be completed. (KleothCore.ScribeError error 1.)".
    private static func userFacing(_ error: any Error) -> String {
        switch error {
        case let scribe as ScribeError:
            // §7: status only — the raw body is logged, never shown (it would
            // size the pill wider than the screen).
            if case .httpError(let status, _) = scribe {
                return "Transcription failed (HTTP \(status))."
            }
            return "Transcription failed: \(scribe.description)"
        case is KleothTimeoutError:
            return "Transcription timed out."
        case let url as URLError:
            return "Network error: \(url.localizedDescription)"
        case let localized as LocalizedError:
            return localized.errorDescription ?? String(describing: error)
        default:
            return String(describing: error)
        }
    }

    // MARK: - Hands-free from the pill (the dock's Dictate field, the menu row)

    /// A hands-free session without the keyboard. The same gates and the same
    /// capture as a chord, then the machine is told (`syncHandsFree(true)`) so
    /// it parks in `handsFree`: the next fn+shift press ends this session as
    /// `.toggledOff`, exactly like one started with a double-tap, and Esc /
    /// the pill ✕ abort it through the paths that already exist. The pill goes
    /// straight to `.listening` — there is no tap to acknowledge first.
    private func startHandsFreeFromPill() {
        switch phase {
        case .idle:
            break
        case .transcribing, .polishing, .inserting:
            refuseWhileBusy()
            return
        case .armed, .listening:
            return   // a session is already live
        }
        guard preflight() else { return }
        target = DictationTarget.frontmost()
        wakeField(of: target)
        armedDismissTask?.cancel()
        armedDismissTask = nil
        capture.inputDeviceId = inputDeviceId
        do {
            try capture.start()
        } catch {
            target = nil
            endFieldSession()
            log.error("dictation capture failed to start: \(error.localizedDescription, privacy: .public)")
            pill.show(.failed(.message(error.localizedDescription)))
            return
        }
        phase = .armed
        monitor.syncHandsFree(true)
        beginListening(handsFree: true)
    }

    /// The click on the hands-free listening capsule. Works for a session the
    /// keyboard started too: the machine sits in `handsFree` either way and is
    /// walked back to idle silently before the clip is committed.
    private func stopHandsFreeFromPill() {
        guard case .listening(handsFree: true) = phase else { return }
        // A double-click on the push-to-talk capsule: its first click latched
        // and the second lands on the now hands-free capsule. Ending the
        // dictation a moment after keeping it going is never what was meant.
        // The user's own double-click speed can be slower than ours.
        let doubleClick = max(DictationDefaults.doubleTapWindow, NSEvent.doubleClickInterval)
        if let latchedAt, latchedAt.duration(to: .now) < .seconds(doubleClick) {
            return
        }
        monitor.syncHandsFree(false)
        finishListening()
    }

    // MARK: - The menu's other rows

    /// "Paste last dictation": the newest log row's text through the same
    /// inserter a dictation uses (snapshot → ⌘V → restore), acknowledged with
    /// the `.done` check. Refused while a session is live — the paste would
    /// land in the middle of it.
    private func pasteLastDictation() {
        guard phase == .idle else { return }
        syncLogStore()
        // A pending row has no text yet: the last dictation that HAS some.
        guard let last = logStore.loadAll(limit: 50).first(where: { !$0.isPending }) else { return }
        let text = last.polishedText.isEmpty ? last.rawText : last.polishedText
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.inserter.insert(text, pressTimeTarget: .frontmost())
                self.pill.show(.done)
            } catch let insertion as TextInsertionError where insertion.textLeftOnClipboard {
                self.pill.show(.warning(insertion.errorDescription ?? "Text copied — press ⌘V."))
            } catch {
                self.pill.show(.failed(.message(error.localizedDescription)))
            }
        }
    }

    /// What the pill's menu shows, asked on every open (`PillMenuContent`):
    /// the connected microphones with the pick and the device in use, the
    /// last dictation's first words, the hotkey.
    private func menuContent() -> PillMenuContent {
        syncLogStore()
        let last = logStore.loadAll(limit: 50).first { !$0.isPending }
        return PillMenuContent(
            microphones: InputDevices.list().map { PillMicrophone(id: $0.id, name: $0.name) },
            selectedMicrophoneId: inputDeviceId,
            inUseMicrophoneName: InputDevices.resolvedName(for: inputDeviceId),
            lastDictationPreview: last.map { Self.preview(of: $0) },
            hotkeyDescription: DictationDefaults.hotkeyDescription
        )
    }

    /// The first words of a log row, one line, for the paste row's subtitle.
    private static func preview(of entry: DictationLogEntry) -> String {
        let text = (entry.polishedText.isEmpty ? entry.rawText : entry.polishedText)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 48 else { return text }
        return String(text.prefix(48)) + "…"
    }

    // MARK: - Pill callbacks

    private func handlePillAction(_ action: DictationPillAction) {
        switch action {
        case .openSettings:
            // The rest of the app opens Settings through SwiftUI's
            // `@Environment(\.openSettings)` (MenuView.swift); the pill is an
            // AppKit panel driven from a controller with no SwiftUI environment,
            // so the responder-chain selector is the only route — don't "fix" it.
            // This is the one place on the dictation path where stealing focus
            // is intended.
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            pill.dismiss()
        case .openAccessibilitySettings:
            AccessibilityPermission.openSystemSettings()
            pill.dismiss()
        case .startScreenRecording, .stopScreenRecording, .revealLastRecording,
             .openScreenRecordingSettings:
            // Never reaches here: `PillCoordinator` routes the recording
            // actions to `ScreenRecordingController` instead of the dictation
            // face (§3.4). Listed so the switch stays exhaustive.
            break
        // The pill menu + peek dock (wired 2026-09-09). None of these dismiss
        // the pill: the menu has already closed, and the resting capsule is
        // exactly what should still be there afterwards.
        case .startHandsFreeDictation:
            startHandsFreeFromPill()
        case .stopHandsFreeDictation:
            stopHandsFreeFromPill()
        case .switchToHandsFree:
            // The click on the push-to-talk capsule, fn+shift still held. The
            // machine decides (a release that got there first wins) and
            // answers with `.latched`, the same event the ⌘ latch sends.
            guard case .listening(handsFree: false) = phase else { return }
            monitor.latch()
        case .selectMicrophone(let id):
            setInputDevice(id)
        case .pasteLastDictation:
            pasteLastDictation()
        case .openDictationHistory:
            requestDictationHistory()
        case .hideForAnHour:
            hidePill()
        case .retryTranscription(let id):
            retryFromPill(id: id)
        }
    }

    /// ✕ or a click on a `.failed` pill. The pill has already hidden itself;
    /// this only matters when a session is somehow still live behind it.
    private func handlePillDismiss() {
        // A dismissed "saved to History" pill just leaves the row in History.
        guard phase != .idle else { return }
        cancel()
    }
}

// MARK: - The focused field (dictation-context design §3.2)

/// `FocusedTextReader` is the only code that reads another app's text; these
/// are the controller's three calls into it, each off the main actor and
/// bounded, plus the session's end. The log gets roles, lengths and timings
/// only — never field text, `replaced_text` or the pasted text.
extension DictationController {
    /// Chord-down (and the pill's Dictate): a wake, nothing more. The reader
    /// reads the target app's role and its focused element's role, which makes
    /// Chromium and Electron build their accessibility tree while the user
    /// speaks. Nothing at all when the setting is off.
    ///
    /// Never awaited, so it needs no deadline: nothing waits for it. A hung
    /// app only keeps the reader's own queue busy for its per-message
    /// timeouts, and the read at release then runs out of its budget.
    private func wakeField(of target: DictationTarget?) {
        guard let processIdentifier = target?.processIdentifier, AppConfig.settings().dictationContext else { return }
        let bundleId = target?.bundleIdentifier
        fieldWoken = true
        Task.detached(priority: .userInitiated) {
            await FocusedTextReader.shared.wake(processIdentifier: processIdentifier, bundleId: bundleId)
        }
    }

    /// Release: one read of the focused field, started at once so it runs
    /// alongside the audio preparation and the upload, and abandoned after
    /// `DictationDefaults.contextReadBudget` (a hung app then costs nothing
    /// but the context; the row stores the budget, §5).
    ///
    /// nil, with nothing read, when the setting is off; when secure input is
    /// on; and when the app in front is no longer the press-time app — the
    /// words were meant for the press-time field, and the row keeps the
    /// press-time app, as today (§5).
    private func readField(of target: DictationTarget?) -> Task<FieldRead, Never>? {
        guard let processIdentifier = target?.processIdentifier, AppConfig.settings().dictationContext else { return nil }
        guard !InsertionEnvironment.isSecureInputActive else {
            log.info("Context snapshot: not read (secure input is on)")
            return nil
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
            log.info("Context snapshot: not read (another app is in front at release)")
            return nil
        }
        let bundleId = target?.bundleIdentifier
        let budget = DictationDefaults.contextReadBudget
        let log = self.log
        return Task.detached(priority: .userInitiated) {
            let started = ContinuousClock.now
            do {
                let snapshot = try await withDeadline(seconds: budget) {
                    await FocusedTextReader.shared.snapshot(processIdentifier: processIdentifier, bundleId: bundleId)
                }
                let (whole, fraction) = started.duration(to: .now).components
                return FieldRead(snapshot: snapshot, seconds: snapshot?.seconds ?? Double(whole) + Double(fraction) / 1e18)
            } catch {
                log.info("Context snapshot: abandoned after \(budget, format: .fixed(precision: 2)) s")
                return FieldRead(snapshot: nil, seconds: budget)
            }
        }
    }

    /// Just before ⌘V: the field read again, abandoned after
    /// `DictationDefaults.contextRecheckBudget` and then treated as unchanged
    /// (§5 "Re-check timed out").
    ///
    /// `.notNeeded`, with nothing read, when there is no field context — the
    /// policy gave none for the snapshot, which the reader can't know — and
    /// for a selection that couldn't be read, which the plan replaces whatever
    /// the field holds now. `.unavailable` while secure input is on.
    private func recheckField(
        _ snapshot: FocusedTextReader.Snapshot?, for field: DictationFieldContext?
    ) async -> DictationInsertionPlan.Recheck {
        guard let snapshot, let field else { return .notNeeded }
        if case .replace = field.verdict { return .notNeeded }
        guard !InsertionEnvironment.isSecureInputActive else { return .unavailable }
        let budget = DictationDefaults.contextRecheckBudget
        do {
            return try await withDeadline(seconds: budget) {
                await FocusedTextReader.shared.recheck(snapshot)
            }
        } catch {
            // Timed out: the snapshot stands. Cancelled (Esc in `.inserting`):
            // the caller ends the run before anything is pasted.
            let why = error is KleothTimeoutError ? "abandoned after the budget" : "cancelled"
            log.info("Context re-check: \(why, privacy: .public)")
            return .unavailable
        }
    }

    /// A session that woke the field is over (or never got going): the reader
    /// sets back any wake attribute it set for it (§5). Not awaited.
    private func endFieldSession() {
        guard fieldWoken else { return }
        fieldWoken = false
        Task.detached(priority: .utility) {
            await FocusedTextReader.shared.endSession()
        }
    }

    /// A field context for the log: where, how, and lengths in characters —
    /// never its text (the verdict's reason is left out too).
    private static func describe(_ field: DictationFieldContext) -> String {
        let verdict = switch field.verdict {
        case .merge: "merge"
        case .append: "append"
        case .replace: "replace"
        }
        return "placement=\(field.placement) verdict=\(verdict) boundary=\(field.boundary) singleLine=\(field.isSingleLine) before=\(field.before.count) selection=\(field.selection.count) after=\(field.after.count)"
    }
}

// MARK: - Kept dictations (dictation-retry design §3.2–§3.5)

extension DictationController {
    /// How a History run ended.
    enum PendingTranscriptionOutcome: Equatable {
        /// Transcribed, polished and copied to the clipboard; the row is filled in.
        case copied
        /// Nothing came of it, and why (also written to the row when the
        /// transcription itself failed).
        case failed(String)
    }

    /// The kept-audio folder next to the day files. Computed from `logStore`,
    /// so it follows wherever Settings moves the output folder.
    private var audioStore: DictationAudioStore {
        DictationAudioStore(dictationsDirectory: logStore.baseDir)
    }

    /// A pending row's kept clip, or nil when the row is not pending or its
    /// file is gone.
    func keptAudioURL(for entry: DictationLogEntry) -> URL? {
        guard let name = entry.audioFileName,
              let url = audioStore.url(forFileNamed: name),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    // MARK: Keeping

    /// Keeps a run's clip so the dictation is not lost. A fresh clip MOVES
    /// into `dictations/audio/` and a pending row is appended; a retry's row
    /// already holds its clip and only records the new reason. Returns the
    /// pending row, or nil when the clip could not be kept — the caller then
    /// falls back to the old plain failure and the run's cleanup deletes the
    /// clip.
    private func keep(_ job: SessionJob, reason: String) async -> DictationLogEntry? {
        if let pending = job.pending {
            return await recordFailure(on: pending, reason: reason)
        }
        let store = audioStore
        let id = UUID().uuidString
        let fileName: String
        do {
            fileName = try store.keep(job.audio, id: id)
        } catch {
            log.error("couldn't keep the dictation audio: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // Out of `$TMPDIR` now: the run's cleanup must not go looking for it.
        inFlightClips.removeAll { $0.standardizedFileURL == job.audio.standardizedFileURL }

        let entry = DictationLogEntry.pending(
            id: id,
            timestamp: DictationLogEntry.isoTimestamp(job.startedAt),
            appBundleId: job.target?.bundleIdentifier,
            appName: job.target?.localizedName,
            durationSeconds: job.durationSeconds,
            audioFileName: fileName,
            transcriptionError: reason
        )
        do {
            try await logStore.append(entry, on: job.startedAt)
        } catch {
            // The clip stays in `audio/`: the launch sweep moves it to the
            // Trash a day later, so it is never silently destroyed.
            log.error("couldn't log the kept dictation: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        logRevision += 1
        log.notice("kept dictation audio \(fileName, privacy: .public): \(reason, privacy: .public)")
        return entry
    }

    /// Brings a pending row's reason up to date (a retry failed, or found no
    /// speech). Returns the row as written, or nil when it is gone — deleted
    /// in History meanwhile — so no Retry is offered for a row that is not
    /// there.
    @discardableResult
    private func recordFailure(on pending: DictationLogEntry, reason: String) async -> DictationLogEntry? {
        var entry = pending
        entry.transcriptionError = reason
        defer { logRevision += 1 }
        do {
            return try await logStore.replace(entry) ? entry : nil
        } catch {
            log.error("couldn't update the kept dictation: \(error.localizedDescription, privacy: .public)")
            return entry   // still on disk as it was: still pending, still retryable
        }
    }

    /// A session that ended without a transcript: keep the clip and offer
    /// Retry on the pill ("Timed out — saved to History"). When the clip
    /// could not be kept, the old sticky failure with `fallback`.
    private func settleFailedRun(
        _ job: SessionJob,
        summary: DictationTranscription.Summary,
        fallback: String
    ) async {
        guard let kept = await keep(job, reason: summary.detail) else {
            pill.show(.failed(.message(fallback)))
            return
        }
        pill.show(.failed(.transcriptionKept("\(summary.cause) — saved to History", dictationId: kept.id)))
    }

    /// A session cancelled before its transcript arrived — Esc, dictation
    /// turned off in Settings, the app quitting. A fresh clip is kept (the
    /// words were already spoken) unless the app is quitting: `shutdown()`
    /// deletes the temp files synchronously and an async keep could not finish
    /// anyway. Esc says where the dictation went; the other paths stay quiet.
    /// A retry's row already holds its clip and stays as it was.
    private func settleCancelledRun(_ job: SessionJob) async {
        let byEscape = stopRequestedByEscape
        guard job.pending == nil, !isShuttingDown else {
            pill.dismiss()
            return
        }
        let kept = await keep(job, reason: "Stopped before the transcript arrived.")
        switch (kept != nil, byEscape) {
        case (true, true):
            pill.show(.warning("Stopped — saved to History"))
        case (false, true):
            // Esc said "stop waiting", not "throw it away" — if the audio
            // could not be kept, say so rather than vanish.
            pill.show(.failed(.message("Stopped — the audio couldn't be saved.")))
        case (_, false):
            pill.dismiss()
        }
    }

    // MARK: Retry from the pill

    /// The Retry button on a "saved to History" pill: a new session over the
    /// kept clip of row `id` — transcribe, polish into the app it was
    /// dictated in, paste into the frontmost app, fill the row in. Refused
    /// for a second while another session is live; a row that has meanwhile
    /// been deleted, transcribed or picked up in History just dismisses the
    /// pill (History shows where it is).
    private func retryFromPill(id: String) {
        switch phase {
        case .idle:
            break
        case .transcribing, .polishing, .inserting:
            refuseWhileBusy()
            return
        case .armed, .listening:
            return
        }
        syncLogStore()
        guard let entry = logStore.entry(id: id), entry.isPending,
              !busyPendingIds.contains(id),
              let audio = keptAudioURL(for: entry)
        else {
            pill.dismiss()
            return
        }
        guard let key = AppConfig.credentials().elevenLabsKey, !key.isEmpty else {
            pill.show(.failed(.missingElevenLabsKey))
            return
        }

        let job = SessionJob(
            audio: audio,
            durationSeconds: entry.durationSeconds ?? 0,
            interrupted: false,
            pending: entry,
            target: DictationTarget(bundleIdentifier: entry.appBundleId, localizedName: entry.appName),
            // No field: the words were spoken earlier, maybe elsewhere (§3.2).
            field: nil
        )
        let settings = AppConfig.settings()
        busyPendingIds.insert(id)
        phase = .transcribing
        isSessionActive = true
        monitor.escapeCancels = true
        pipelineTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.busyPendingIds.remove(id)
                self.finishPipeline()
            }
            await self.runSession(job, key: key, settings: settings)
        }
    }

    // MARK: Transcribe from History

    /// Transcribes a kept dictation from History — a background job: no pill,
    /// no session, never a paste. The text is polished like a dictation into
    /// the row's app and copied to the clipboard; the row is filled in and its
    /// clip deleted. On device goes through the shared pipeline queue (never
    /// two WhisperKit engines at once); the cloud runs straight away.
    func transcribePending(id: String, onDevice: Bool) async -> PendingTranscriptionOutcome {
        syncLogStore()
        guard !busyPendingIds.contains(id) else {
            return .failed("This dictation is already being transcribed.")
        }
        guard let entry = logStore.entry(id: id), entry.isPending else {
            return .failed("This dictation is no longer waiting to be transcribed.")
        }
        guard let audio = keptAudioURL(for: entry) else {
            return .failed("The audio file is missing.")
        }
        let settings = AppConfig.settings()
        let transcriber: any Transcriber
        let policy: DictationTranscription.Policy
        if onDevice {
            transcriber = LocalTranscriber(
                language: RecordingController.normalizedTranscriptionLanguage(settings.transcriptionLanguage)
            )
            policy = .onDevice
        } else {
            guard let key = AppConfig.credentials().elevenLabsKey, !key.isEmpty else {
                return .failed("Add an ElevenLabs API key in Settings to transcribe in the cloud.")
            }
            transcriber = injectedTranscriber ?? makeTranscriber(elevenLabsKey: key)
            policy = .scribe(audioSeconds: entry.durationSeconds ?? 0)
        }

        busyPendingIds.insert(id)
        defer { busyPendingIds.remove(id) }

        let polisherTask = Task { try await AppConfig.makePolisher() }
        let terms = Keyterms.sanitize(dictionary.load())
        let options = ScribeOptions.dictation(keyterms: terms)
        let work: @Sendable () async throws -> DictationTranscription.Result = {
            try await DictationTranscription.run(
                transcriber,
                fileURL: audio,
                options: options,
                policy: policy,
                onAttemptFailed: DictationController.logFailedAttempt
            )
        }
        let transcription: DictationTranscription.Result
        do {
            transcription = onDevice ? try await onPipelineQueue(work) : try await work()
        } catch let failure as DictationTranscription.Failure {
            log.error("History transcription failed: \(String(describing: failure), privacy: .public)")
            let summary = DictationTranscription.summary(of: failure, attempts: failure.attempts)
            await recordFailure(on: entry, reason: summary.detail)
            return .failed(summary.detail)
        } catch {
            return .failed("Stopped before the transcript arrived.")
        }
        let rawText = Self.extractText(transcription.response)
        guard !rawText.isEmpty else {
            let reason = "No speech was found in the audio."
            await recordFailure(on: entry, reason: reason)
            return .failed(reason)
        }

        let context = DictationContext(
            appBundleId: entry.appBundleId,
            appName: entry.appName,
            languageCode: transcription.response.languageCode,
            dictionary: terms
        )
        // No field: the words were spoken earlier, maybe elsewhere (§3.2).
        let polish = await polish(
            rawText, context: context, field: nil, settings: settings, polisherTask: polisherTask,
            interactive: false
        )
        // Never between a live session's clipboard write and its ⌘V (the
        // inserter can wait out held modifier keys in between): the paste
        // would carry this text into the frontmost app instead.
        while phase == .inserting {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(polish.result.text, forType: .string)

        let resolved = makeEntry(
            pending: entry,
            durationSeconds: entry.durationSeconds ?? 0,
            transcription: transcription,
            transcriber: transcriber,
            options: options,
            terms: terms,
            rawText: rawText,
            polish: polish,
            context: context,
            method: .notInserted
        )
        await persist(resolved, resolving: entry)
        return .copied
    }

    /// Runs `work` as one job on `RecordingController`'s FIFO — the queue every
    /// `LocalTranscriber` run shares, so two ~600 MB WhisperKit engines never
    /// load at once — and hands its result back.
    private func onPipelineQueue<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let queue = RecordingController.shared else { return try await work() }
        return try await withCheckedThrowingContinuation { continuation in
            queue.enqueuePipelineJob {
                do {
                    continuation.resume(returning: try await work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Housekeeping

    /// Launch: kept clips no row points at any more (a keep whose row never
    /// landed, a hand-edited day file) go to the Trash once they are a day
    /// old. Off the main actor — it reads every day file.
    private func sweepOrphanedAudio() {
        syncLogStore()
        let store = logStore
        let audio = audioStore
        Task.detached(priority: .utility) {
            // Every kept clip older than a day, then the ones no record still
            // names. Fails closed: when a record can't be read at all, the
            // sweep trashes nothing.
            let old = audio.orphans(referenced: [], olderThan: DictationDefaults.orphanedAudioMaxAge)
            guard !old.isEmpty,
                  let mentioned = store.audioFileNamesMentioned(among: Set(old.map(\.lastPathComponent)))
            else { return }
            let log = Logger(subsystem: "dev.kleoth", category: "Dictation")
            for url in old where !mentioned.contains(url.lastPathComponent) {
                if audio.trash(fileNamed: url.lastPathComponent) {
                    log.notice("moved orphaned dictation audio to the Trash: \(url.lastPathComponent, privacy: .public)")
                }
            }
        }
    }
}
