import AppKit
import AVFoundation
import Foundation
import KleothCapture
import KleothCore
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
    @Published private(set) var isMonitoring: Bool
    @Published private(set) var dictationModel: String
    /// True from `.began`/`.toggledOn` until `endSession()` (listening or pipeline in flight).
    @Published private(set) var isSessionActive: Bool = false
    /// Bumped AFTER `await logStore.append` returns (the row is on disk); DictationsListView reloads on change.
    @Published private(set) var logRevision: Int = 0

    let logStore: DictationLogStore

    private let monitor: any DictationHotkeyMonitoring
    private let pill: any DictationPillPresenting
    private let inserter: any TextInserting
    private let dictionary: PersonalDictionaryStore
    /// The STT seam. nil in production → `makeTranscriber(elevenLabsKey:)` builds a
    /// `ScribeClient` per run (the key can change in Settings between dictations).
    /// Injected by the `dictate` probe / tests.
    private let injectedTranscriber: (any Transcriber)?

    /// Short-timeout session: `URLSessionTransport.defaultSession` waits 1200 s between bytes.
    private let transport = URLSessionTransport(session: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
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
    /// 20 Hz `capture.currentLevel` → `PillGeometry` → `pill.setLevel`.
    private var levelTask: Task<Void, Never>?
    /// Restores the pill's pipeline phase after the 1 s "Finishing the previous
    /// dictation…" refusal (a plain `.warning` would auto-hide the pill mid-run).
    private var refusalTask: Task<Void, Never>?
    /// The app that had focus at chord-down (prompt + log). Paste goes to
    /// whoever is frontmost at paste time — the inserter samples again.
    private var target: DictationTarget?
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
            pill: DictationPillController(),
            inserter: TextInserter.shared,
            logStore: DictationLogStore(outputDir: settings.outputDir),
            dictionary: PersonalDictionaryStore(),
            transcriber: nil
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
        transcriber: (any Transcriber)? = nil
    ) {
        let settings = AppConfig.settings()
        self.monitor = monitor
        self.pill = pill
        self.inserter = inserter
        self.logStore = logStore
        self.dictionary = dictionary
        self.injectedTranscriber = transcriber
        self.isEnabled = settings.dictationEnabled
        self.isTrusted = AccessibilityPermission.isTrusted
        self.isMonitoring = false
        self.dictationModel = settings.dictationModel

        pill.onAction = { [weak self] action in self?.handlePillAction(action) }
        pill.onDismiss = { [weak self] in self?.handlePillDismiss() }
    }

    /// Default engine factory; the only place `ScribeClient` is named in this file.
    private func makeTranscriber(elevenLabsKey: String) -> any Transcriber {
        ScribeClient(apiKey: elevenLabsKey, transport: transport)
    }

    // MARK: - Lifecycle

    /// AppDelegate.applicationDidFinishLaunching (via MainActor.assumeIsolated).
    func startIfEnabled() {
        DictationCapture.sweepStaleClips()
        ensureEventLoop()
        refreshTrust()
        guard isEnabled else { return }
        installMonitorIfPossible()
    }

    /// applicationWillTerminate: cancel(); monitor.stop(); eventTask?.cancel().
    /// Synchronous on purpose — the process may exit before any hop runs.
    func shutdown() {
        cancel()
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
        case .listening:
            capture.cancel()
            pill.dismiss()
            endSession()
        case .transcribing, .polishing, .inserting:
            pipelineTask?.cancel()
            pill.dismiss()
        }
    }

    // MARK: - Settings surface

    /// Keychain + (un)install; prompts for Accessibility when turning on untrusted.
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
        let resolved = trimmed.isEmpty ? DictationDefaults.polishModel : ModelCatalog.migrating(trimmed)
        Keychain.set(resolved, Keychain.Account.dictationModel)
        dictationModel = resolved
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
        logStore.loadAll(limit: limit)
    }

    /// Hops to the store actor; bumps logRevision.
    func deleteDictations(ids: Set<String>) async throws {
        _ = try await logStore.delete(ids: ids)
        logRevision += 1
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

        guard isEnabled else { return }
        guard AccessibilityPermission.isTrusted else {
            isTrusted = false
            pill.show(.failed(.needsAccessibility))
            return
        }
        let credentials = AppConfig.credentials()
        guard let key = credentials.elevenLabsKey, !key.isEmpty else {
            pill.show(.failed(.missingElevenLabsKey))
            return
        }
        guard RecordingController.microphoneStatus() != .denied else {
            pill.show(.failed(.message(DictationError.microphoneDenied.errorDescription ?? "Kleoth needs microphone access.")))
            return
        }
        guard !InsertionEnvironment.isSecureInputActive else {
            pill.show(.failed(.secureInput))
            return
        }

        target = DictationTarget.frontmost()
        do {
            try capture.start()
        } catch {
            target = nil
            pill.show(.failed(.message(error.localizedDescription)))
            return
        }
        phase = .armed
    }

    /// `.began` (push-to-talk confirmed) / `.toggledOn` (hands-free): the pill appears.
    private func beginListening(handsFree: Bool) {
        guard phase == .armed else { return }
        phase = .listening(handsFree: handsFree)
        monitor.escapeCancels = true
        isSessionActive = true
        pill.show(.listening(handsFree: handsFree))
        startLevelPoll()
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
        pipelineTask = Task { [weak self] in
            await self?.run(clip: clip, target: pressTimeTarget)
        }
    }

    private func handleCancelled(_ reason: DictationHotkeyEvent.CancelReason) {
        switch phase {
        case .armed:
            capture.cancel()
            phase = .idle
            target = nil
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

    private func handleEscape() {
        switch phase {
        case .listening:
            capture.cancel()
            pill.dismiss()
            endSession()
        case .transcribing, .polishing, .inserting:
            pipelineTask?.cancel()
            pill.dismiss()
        case .idle, .armed:
            break
        }
    }

    /// The ONLY place the session flags go back down (§2.3).
    private func endSession() {
        phase = .idle
        monitor.escapeCancels = false
        isSessionActive = false
        stopLevelPoll()
        target = nil
    }

    /// A chord press while steps 5–8 are in flight: refuse, but say so. The
    /// warning is shown for 1 s and then the phase's own pill state returns —
    /// a bare `.warning` would auto-hide the pill after 3 s while the pipeline
    /// is still running. The machine goes on to emit `.began`/`.ended` for this
    /// press; both are ignored because `phase` is not `.armed`/`.listening`.
    private func refuseWhileBusy() {
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

    /// Prepare → transcribe → polish → insert → log → settle. `prepared` is
    /// declared before the `defer` so the `defer` can legally reference it; that
    /// single `defer` also owns every flag reset (`endSession()`), so every exit
    /// — success, early return, `.failed`, cancellation — tears down the same way.
    private func run(clip: DictationCaptureResult, target: DictationTarget?) async {
        var prepared: URL?
        defer {
            DictationCapture.discard(clip.fileURL)
            prepared.map(DictationCapture.discard)
            refusalTask?.cancel()
            refusalTask = nil
            pipelineTask = nil
            endSession()
        }

        let credentials = AppConfig.credentials()
        let settings = AppConfig.settings()
        guard let key = credentials.elevenLabsKey, !key.isEmpty else {
            pill.show(.failed(.missingElevenLabsKey))   // also checked at `armed`
            return
        }

        // 5. Prepare (off-main): mono downmix + loudness/peak normalize, 64 kbps.
        let uploadURL: URL
        do {
            let raw = clip.fileURL
            uploadURL = try await Task.detached(priority: .userInitiated) {
                try DictationCapture.prepareForUpload(raw)
            }.value
            prepared = uploadURL
            // `.value` on a detached task does not propagate our cancellation.
            try Task.checkCancellation()
        } catch is CancellationError {
            pill.dismiss()
            return
        } catch {
            pill.show(.failed(.message("Couldn't prepare the audio (\(error.localizedDescription)).")))   // NO log row
            return
        }

        // 6. Transcribe through the `Transcriber` seam.
        let terms = Keyterms.sanitize(dictionary.load())
        let transcriber: any Transcriber = injectedTranscriber ?? makeTranscriber(elevenLabsKey: key)
        pill.show(.transcribing)
        let response: ScribeResponse
        do {
            response = try await withTimeout(seconds: DictationDefaults.scribeTimeout) {
                try await transcriber.transcribe(fileURL: uploadURL, options: .dictation(keyterms: terms))
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            pill.dismiss()
            return
        } catch {
            log.error("transcription failed: \(Self.userFacing(error), privacy: .public)")
            pill.show(.failed(.message(Self.userFacing(error))))   // NO log row
            return
        }
        let rawText = Self.extractText(response)
        guard !rawText.isEmpty else {
            pill.show(.warning("Nothing was heard."))
            return
        }

        // 7. Polish (non-throwing; raw fallback built in).
        let context = DictationContext(
            appBundleId: target?.bundleIdentifier,
            appName: target?.localizedName,
            languageCode: response.languageCode,
            dictionary: terms
        )
        phase = .polishing
        pill.show(.polishing)
        let polish: DictationPolishResult
        if let openRouterKey = credentials.openRouterKey, !openRouterKey.isEmpty {
            let polisher = DictationPolisher(
                client: OpenRouterClient(apiKey: openRouterKey, transport: transport),
                model: settings.dictationModel
            )
            polish = await polisher.polish(rawText: rawText, context: context)
        } else {
            polish = .raw(text: rawText, reason: "No OpenRouter key — pasted the raw transcript.")
        }
        // Esc during the polish call: the polisher swallows cancellation into a
        // `.raw` result, so check here before anything reaches the pasteboard.
        guard !Task.isCancelled else {
            pill.dismiss()
            return
        }

        // 8. Insert.
        phase = .inserting
        var method = DictationInsertMethod.paste
        var warning = polish.fallbackReason
        do {
            try await inserter.insert(polish.text, pressTimeTarget: target ?? .frontmost())
        } catch let insertion as TextInsertionError where insertion.textLeftOnClipboard {
            method = .clipboard
            warning = insertion.errorDescription
        } catch {
            pill.show(.failed(.message(error.localizedDescription)))
            return
        }

        // 9. Log (actor-serialized, off-main), then bump the revision.
        let surcharge = terms.isEmpty ? 1 : DictationDefaults.keytermSurchargeMultiplier
        let entry = DictationLogEntry(
            timestamp: DictationLogEntry.isoTimestamp(Date()),
            appBundleId: context.appBundleId,
            appName: context.appName,
            language: response.languageCode,                    // Scribe's code wins on disk
            rawText: rawText,
            polishedText: polish.text,
            usedRawFallback: polish.usedRawFallback,
            fallbackReason: polish.fallbackReason,
            transcriptionModel: DictationDefaults.transcriptionModel,
            polishModel: polish.usedRawFallback ? nil : settings.dictationModel,
            durationSeconds: clip.durationSeconds,
            insertMethod: method,
            transcriptionCost: transcriber.usdPerHour * clip.durationSeconds / 3600 * surcharge,
            polishCost: polish.cost
        )
        do {
            try await logStore.append(entry)
        } catch {
            log.error("dictation log append failed: \(error.localizedDescription, privacy: .public)")
        }
        logRevision += 1   // AFTER the row is on disk

        // 10. Settle.
        pill.show(warning.map { .warning($0) } ?? .done)
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
        case .openAccessibilitySettings:
            AccessibilityPermission.openSystemSettings()
        }
        pill.dismiss()
    }

    /// ✕ or a click on a `.failed` pill. The pill has already hidden itself;
    /// this only matters when a session is somehow still live behind it.
    private func handlePillDismiss() {
        guard phase != .idle else { return }
        cancel()
    }
}
