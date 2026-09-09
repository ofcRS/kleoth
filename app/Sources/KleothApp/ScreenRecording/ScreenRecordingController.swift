import AppKit
import AVFoundation
import Foundation
import KleothCapture
import KleothCore
import KleothPillUI
import os

/// Owns one screen-recording session end to end: permission, region pick,
/// `ScreenRecorder`, the pill backdrop, the recovered-file sweep, and the quit
/// hand-off (design §3.4). `@MainActor`, app-lifetime `shared` — the
/// `RecordingController` / `DictationController` shape.
///
/// The session's life is the pure `ScreenRecordingSessionMachine`: every
/// transition goes through `apply(_:)` and the `Effect` it returns is dispatched
/// by `perform(_:)` to exactly one method. Nothing else mutates `machineState`,
/// so "what is this controller doing" has one answer that a test can construct
/// without a display.
@MainActor
final class ScreenRecordingController: ObservableObject {
    private(set) static var shared: ScreenRecordingController?

    /// The pure session machine's state — the single source of truth every
    /// surface reads.
    @Published private(set) var machineState: ScreenRecordingSessionMachine.State = .idle
    @Published private(set) var lastSummary: ScreenRecordingSummary?
    /// "Stopped: the display disconnected" / "mic dropped for 1.2 s at 3:12" /
    /// "Recovered a screen recording" — one line for the popover.
    @Published private(set) var lastStopDetail: String?
    @Published private(set) var permissionState: ScreenRecordingPermission.State = .notDetermined

    // MARK: - Recordings library state

    /// Every finished movie in the recordings folder, newest first — what the
    /// History window's **Recordings** scope lists. Reloaded off the main actor
    /// (`reloadRecordings()`), never scanned from a view.
    @Published private(set) var recordings: [ScreenRecordingItem] = []
    /// Standardized movie paths whose transcription is queued or running — the
    /// `RecordingController.processingPaths` idiom, and in-memory for the same
    /// reason: a quit mid-job leaves the row untranscribed, which is the truth.
    @Published private(set) var transcribingPaths: Set<String> = []
    /// Set by the popover to deep-link History to one recording.
    @Published var selectedRecordingID: ScreenRecordingItem.ID?
    /// Bumped every time the popover opens History *for recordings*. The window
    /// observes it to flip its scope — `selectedRecordingID` alone cannot carry
    /// a repeat click on the recording that is already selected. Mirrors
    /// `RecordingController.meetingsHistoryRequest`.
    @Published var recordingsHistoryRequest: Int = 0

    /// Where a start came from — the pill or the popover row (§2.2).
    enum Origin {
        case pill
        case popover
    }

    private let coordinator: PillCoordinator
    private let defaults: UserDefaults
    private let log = Logger(subsystem: "dev.kleoth", category: "ScreenRecording")

    // MARK: - Session state

    private var machine = ScreenRecordingSessionMachine()
    private var recorder: ScreenRecorder?
    /// The region the picker returned, consumed by `startCapture()`.
    private var pendingChoice: RegionPicker.Choice?
    /// `.stopping(reason:)` loses its payload the moment the machine moves on to
    /// `.saving`, but `ScreenRecorder.stop(reason:)` still needs it.
    private var pendingStopReason: ScreenRecordingStopReason?
    /// Set by a `writerFailed` event so the finalize path can report §7 row 13
    /// even when `finishWriting` itself succeeds on the fragments so far.
    private var writerFailureMessage: String?
    /// Why `recorder.start()` threw AFTER a stop had already moved the machine
    /// past `.starting`. `finalize()` surfaces it instead of a generic
    /// "Nothing was recorded." — a stale permission or a missing display is
    /// actionable, an empty file is not.
    private var startFailure: ScreenRecordingFailure?
    /// Overrides the pill state `showFailed()` would derive from the failure.
    /// Only `finalizeTimedOut` uses it: §7 row 24 is a WARNING over a saved
    /// file, not a sticky fault, but the machine still has to leave `.saving`.
    private var faultOverride: DictationPillState?
    private var micDenied = false
    private var micGapStart: TimeInterval?
    /// Offset of a `micLost` event: §7 row 16 ends such a session with a
    /// warning rather than the plain `.saved` confirmation.
    private var micLostAt: TimeInterval?

    private var pickTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var finalizeTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var refusalTask: Task<Void, Never>?

    /// The in-flight library listing — cancelled by the next reload so a burst
    /// (save → reload, trash → reload) publishes once.
    private var reloadTask: Task<Void, Never>?
    /// The 20 Hz `recorder.levels` → pill pump, alive only while recording.
    private var levelPumpTask: Task<Void, Never>?

    private var terminationCompletion: (@MainActor () -> Void)?
    private var terminationTimeoutTask: Task<Void, Never>?

    /// The `refuseWhileBusy` display budget (`DictationController` uses the same
    /// one second for the same reason).
    private static let refusalDisplayDuration: Duration = .seconds(1)

    convenience init() {
        self.init(coordinator: PillCoordinator.shared, defaults: .standard)
        Self.shared = self
    }

    init(coordinator: PillCoordinator, defaults: UserDefaults) {
        self.coordinator = coordinator
        self.defaults = defaults
        permissionState = ScreenRecordingPermission.state(defaults: defaults)
        coordinator.onRecordingAction = { [weak self] action in
            self?.handlePillAction(action)
        }
    }

    /// Pill backdrop, menu-bar glyph, quit guard, popover row.
    var isActive: Bool {
        switch machineState {
        case .idle, .saved, .failed: return false
        case .checkingPermission, .pickingRegion, .starting, .recording, .stopping, .saving: return true
        }
    }

    /// The session's fixed start — the popover's `TimelineView` digits.
    var since: Date? {
        switch machineState {
        case .starting(let since), .recording(let since): return since
        case .idle, .checkingPermission, .pickingRegion, .stopping, .saving, .saved, .failed: return nil
        }
    }

    // MARK: - Commands

    /// Preflight → picker → pill `.recording` → `recorder.start()`; every
    /// failure becomes a sticky fault (§7).
    func start(from origin: Origin) {
        let now = Date()
        guard let effect = apply(.startRequested(now)) else {
            // The machine refused. From an ACTIVE state that is §7 row 7; from
            // `.idle` / `.saved` / `.failed` it would be a machine bug, and the
            // button would look dead — so say which one it was.
            if isActive {
                log.notice("screen recording start from \(String(describing: origin), privacy: .public) refused — already active")
            } else {
                log.error("screen recording start refused from an inactive state: \(String(describing: self.machineState), privacy: .public)")
            }
            refuseAlreadyActive()
            return
        }
        log.notice("screen recording start from \(String(describing: origin), privacy: .public)")
        // The previous session's confirmation or sticky fault is still on the
        // pill, and `setBackdrop` only takes over a RESTING-family phase — so
        // without this the new `.recording(since:)` would merely be stored and
        // the whole recording would run behind a stale "…try again" (§7 rows
        // 21-22). The coordinator only ever drops recording-owned phases, so a
        // live dictation is untouched.
        coordinator.dismissRecordingPhase()
        perform(effect)
    }

    /// The user asked to stop: the pill, the popover row, the menu.
    func stop() {
        requestStop(.user)
    }

    /// `NSWorkspace.activateFileViewerSelecting`.
    func revealLast() {
        guard let url = lastSummary?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyLastPath() {
        guard let url = lastSummary?.url else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    /// Settings button; creates the folder when it is missing so the reveal
    /// always lands somewhere.
    func openRecordingsFolder() {
        let dir = recordingsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    /// 1 Hz while the Settings pane is open, and on `didBecomeActive`.
    func refreshPermission() {
        let state = ScreenRecordingPermission.state(defaults: defaults)
        if permissionState != state { permissionState = state }
    }

    // MARK: - Recordings library

    /// Re-lists the recordings folder. The directory walk (one `stat` and one
    /// sidecar read per file) runs off the main actor; only the finished array
    /// is published, so a big folder never stutters the History window.
    func reloadRecordings() {
        let dir = recordingsDirectory()
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            let items = await Task.detached(priority: .utility) {
                ScreenRecordingStore.listRecordings(in: dir)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.reloadTask = nil
            if self.recordings != items { self.recordings = items }
        }
    }

    /// True while a transcription for this recording is queued or running.
    func isTranscribing(_ item: ScreenRecordingItem) -> Bool {
        transcribingPaths.contains(item.id)
    }

    /// Persists a sidecar the viewer edited (a word, a title) and republishes
    /// the row in place, so the detail pane and the list agree before the
    /// (asynchronous) reload lands. The library is the ONLY writer of a
    /// sidecar — the viewer hands its record here.
    func saveRecord(_ record: ScreenRecordingRecord, for item: ScreenRecordingItem) {
        do {
            try ScreenRecordingStore.saveRecord(record, for: item.url)
        } catch {
            log.error("could not write a recording sidecar: \(String(describing: error), privacy: .public)")
            return
        }
        republish(record, for: item.id)
        reloadRecordings()
    }

    /// Moves the movie and its sidecar to the Trash (recoverable — so, like the
    /// meetings list, no confirmation).
    func trash(_ item: ScreenRecordingItem) {
        do {
            try ScreenRecordingStore.trash(item.url)
        } catch {
            log.error("could not trash a recording: \(String(describing: error), privacy: .public)")
            return
        }
        // The popover's "Last screen recording" row must not point at a file in
        // the Trash.
        if lastSummary?.url.standardizedFileURL == item.url.standardizedFileURL {
            lastSummary = nil
            lastStopDetail = nil
        }
        recordings.removeAll { $0.id == item.id }
        reloadRecordings()
    }

    func reveal(_ item: ScreenRecordingItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// Replaces one row's record without re-listing the folder.
    private func republish(_ record: ScreenRecordingRecord, for id: ScreenRecordingItem.ID) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[index].record = record
    }

    // MARK: - Transcription

    /// Queues ONE transcription of `item` on the shared pipeline queue
    /// (`RecordingController.enqueuePipelineJob`): every `LocalTranscriber` run
    /// loads its own ~600 MB WhisperKit, so a screen recording and a meeting must
    /// never transcribe at the same time.
    ///
    /// `tier` is `TranscriptTier.local` (on-device, free) or `.sotaScribe`
    /// (ElevenLabs). No spend confirmation, matching the meetings surface.
    func transcribe(_ item: ScreenRecordingItem, tier: String) {
        let path = item.id
        guard !transcribingPaths.contains(path) else { return }
        guard FileManager.default.fileExists(atPath: item.url.path) else {
            log.error("cannot transcribe a recording that is gone: \(path, privacy: .public)")
            reloadRecordings()
            return
        }

        var elevenKey: String?
        if TranscriptTier.isSOTA(tier) {
            let key = AppConfig.credentials().elevenLabsKey ?? ""
            guard !key.isEmpty else {
                // Refused before anything is queued — but the row has to say
                // why, so the refusal is written like any other failure.
                writeTranscriptFailure(
                    "Add an ElevenLabs API key in Settings to transcribe in the cloud.",
                    movieURL: item.url,
                    existing: item.record
                )
                reloadRecordings()
                return
            }
            elevenKey = key
        }
        // The SAME normalization the meetings pipeline uses: empty / "auto" is
        // nil (detect), anything else is a pinned Whisper code.
        let language = RecordingController.normalizedTranscriptionLanguage(
            AppConfig.settings().transcriptionLanguage
        )

        guard let queue = RecordingController.shared else {
            log.error("no RecordingController to queue a transcription on")
            return
        }
        transcribingPaths.insert(path)
        let url = item.url
        let existing = item.record
        queue.enqueuePipelineJob { [weak self] in
            await self?.runTranscription(
                movieURL: url,
                existing: existing,
                tier: tier,
                language: language,
                elevenKey: elevenKey
            )
        }
    }

    /// The queued worker: extract the audio, run the engine, write the sidecar.
    /// Everything expensive (the export, the model, the upload) is a
    /// `nonisolated` async call, so it suspends this main-actor job rather than
    /// blocking the UI.
    private func runTranscription(
        movieURL: URL,
        existing: ScreenRecordingRecord?,
        tier: String,
        language: String?,
        elevenKey: String?
    ) async {
        let path = movieURL.standardizedFileURL.path
        defer {
            transcribingPaths.remove(path)
            reloadRecordings()
        }

        let tempDir = Self.transcriptionScratchDirectory
        let audioURL = tempDir
            .appendingPathComponent(movieURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("m4a")
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            log.error("recordings temp dir unusable: \(String(describing: error), privacy: .public)")
            writeTranscriptFailure(error.localizedDescription, movieURL: movieURL, existing: existing)
            return
        }
        // The movie is the artifact the user keeps; the extracted audio is
        // scratch and goes on every exit, thrown or not.
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            try await RecordingAudioExtractor.extractAudio(from: movieURL, to: audioURL)

            let transcriber: any Transcriber
            var options = ScribeOptions()
            if let elevenKey {
                transcriber = ScribeClient(apiKey: elevenKey, transport: URLSessionTransport())
                // One mixed track, one channel — and the viewer highlights
                // WORDS, not speaker turns, so diarization would only cost time.
                options.diarize = false
                options.useMultiChannel = false
                options.tagAudioEvents = false
                options.languageCode = language
            } else {
                transcriber = LocalTranscriber(language: language, wordTimestamps: true)
            }

            let response = try await transcriber.transcribe(fileURL: audioURL, options: options)
            let words = ScreenRecordingRecord.words(from: response)
            let duration = await Self.duration(
                reported: response.audioDurationSecs,
                of: audioURL,
                fallback: existing?.durationSecs
            )

            var record = existing ?? ScreenRecordingRecord()
            record.schemaVersion = ScreenRecordingRecord.currentSchemaVersion
            record.durationSecs = duration
            record.languageCode = response.languageCode
            record.transcriptTier = tier
            record.transcriptModel = transcriber.modelIdentifier(for: options)
            record.transcribedAt = Date()
            record.words = words
            // A run that produced nothing is not something the viewer can show,
            // and leaving the row "Untranscribed" would look like the button did
            // nothing — so the empty result says so out loud.
            record.transcriptError = words.isEmpty ? "No speech was found in this recording." : nil
            try ScreenRecordingStore.saveRecord(record, for: movieURL)
            republish(record, for: path)
            log.notice("transcribed \(movieURL.lastPathComponent, privacy: .public): \(words.count) words (\(tier, privacy: .public))")
        } catch {
            log.error("transcription failed for \(movieURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            writeTranscriptFailure(error.localizedDescription, movieURL: movieURL, existing: existing)
        }
    }

    /// `$TMPDIR/kleoth-recordings` — where a recording's audio is extracted to
    /// before it is transcribed. Scratch: emptied at launch, and every job
    /// deletes its own file in a `defer`.
    private static var transcriptionScratchDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kleoth-recordings", isDirectory: true)
    }

    /// Wall clock for the recording: what the engine reported, else the file
    /// itself (probed off the main actor — it opens the audio), else whatever
    /// the sidecar already knew.
    private static func duration(reported: Double?, of audioURL: URL, fallback: Double?) async -> Double? {
        if let reported { return reported }
        let probed = await Task.detached(priority: .utility) {
            AudioProbe.durationSeconds(of: audioURL)
        }.value
        return probed ?? fallback
    }

    /// Records WHY a transcription could not be produced. An existing transcript
    /// is never wiped by a failed retry — the words stay and the error rides
    /// alongside them.
    private func writeTranscriptFailure(_ message: String, movieURL: URL, existing: ScreenRecordingRecord?) {
        var record = existing ?? ScreenRecordingRecord()
        record.transcriptError = message
        do {
            try ScreenRecordingStore.saveRecord(record, for: movieURL)
            republish(record, for: movieURL.standardizedFileURL.path)
        } catch {
            log.error("could not record a transcription failure: \(String(describing: error), privacy: .public)")
        }
    }

    /// A recording the user just finished: seed its sidecar with the duration
    /// the session already measured (so the row reads right even if the
    /// transcription fails), list it, and start the on-device pass
    /// automatically. Recovered files and older untranscribed ones are left
    /// alone — the viewer's button is how those get transcribed.
    private func handleFreshRecording(_ summary: ScreenRecordingSummary) {
        let stored = ScreenRecordingStore.loadRecord(for: summary.url)
        let record = stored ?? ScreenRecordingRecord(durationSecs: summary.duration)
        if stored == nil {
            do {
                try ScreenRecordingStore.saveRecord(record, for: summary.url)
            } catch {
                log.error("could not seed a recording sidecar: \(String(describing: error), privacy: .public)")
            }
        }
        let item = ScreenRecordingItem(
            url: summary.url,
            recordedAt: ScreenRecordingFileNaming.date(fromStemOf: summary.url) ?? Date(),
            sizeBytes: summary.fileSizeBytes,
            record: record
        )
        reloadRecordings()
        transcribe(item, tier: TranscriptTier.local)
    }

    // MARK: - Level pump

    /// 20 Hz `recorder.levels` → the pill's recording meters. Deliberately a
    /// polling loop rather than a callback out of the capture lanes: the meter
    /// only needs the most recent value, and a dropped tick is invisible.
    private func startLevelPump() {
        levelPumpTask?.cancel()
        levelPumpTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let recorder = self.recorder else { return }
                self.coordinator.setRecordingLevels(recorder.levels)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Stops the pump and parks the meters at zero, so a stopped session can
    /// never leave the pill holding the last live level.
    private func stopLevelPump() {
        guard levelPumpTask != nil else { return }
        levelPumpTask?.cancel()
        levelPumpTask = nil
        coordinator.setRecordingLevels(.zero)
    }

    /// Launch: sweep leftover `*.recording.mp4` → `-recovered` / trash, then
    /// `refreshPermission()`.
    func startIfNeeded() {
        refreshPermission()
        // Async on purpose: probing a leftover file's duration is an
        // `AVURLAsset.load` away, and blocking `applicationDidFinishLaunching`
        // on I/O would delay the menu-bar item. Unlike the terminate hook there
        // is no risk of the process exiting before the hop runs.
        Task { @MainActor [weak self] in
            await self?.sweepInterruptedRecordings()
            // After the sweep, so a recovered file is listed under its final
            // name. Recovered and older untranscribed files are NOT
            // auto-transcribed — only a recording this launch just finished is.
            self?.reloadRecordings()
        }
        // A process killed mid-extraction leaves an .m4a behind; nothing can be
        // using the folder at launch, so it goes wholesale (the dictation
        // temp-clip sweep's reasoning).
        try? FileManager.default.removeItem(at: Self.transcriptionScratchDirectory)
    }

    /// Quit path. Returns false immediately when nothing is recording;
    /// otherwise begins `stop(.quit)` and calls `completion` on the main actor
    /// when the file is finalized or `finalizeTimeout` expires. Synchronous
    /// entry on purpose — `applicationShouldTerminate` runs on the main thread
    /// and the process may exit before any hop.
    func beginTerminationStop(completion: @escaping @MainActor () -> Void) -> Bool {
        guard isActive else { return false }
        terminationCompletion = completion
        terminationTimeoutTask?.cancel()
        // The app is `.terminateLater` from here: the run loop keeps spinning,
        // so this sleep really does fire.
        terminationTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(ScreenRecordingDefaults.finalizeTimeout))
            guard !Task.isCancelled else { return }
            self?.log.error("screen recording finalize exceeded the terminate budget — replying anyway")
            self?.finishTermination()
        }
        requestStop(.quit)
        return true
    }

    // MARK: - Machine

    @discardableResult
    private func apply(_ event: ScreenRecordingSessionMachine.Event) -> ScreenRecordingSessionMachine.Effect? {
        let effect = machine.apply(event)
        if machineState != machine.state { machineState = machine.state }
        return effect
    }

    /// One effect, one method — the whole controller's control flow.
    private func perform(_ effect: ScreenRecordingSessionMachine.Effect?) {
        guard let effect else { return }
        switch effect {
        case .requestPermission: checkPreflight()
        case .presentPicker: presentPicker()
        case .startCapture: startCapture()
        case .showRecording: showRecording()
        case .stopCapture: stopCapture()
        case .finalize: finalize()
        case .showSaved: showSaved()
        case .showFailed: showFailed()
        case .reset: resetSession()
        }
    }

    // MARK: - Effects

    /// Screen Recording TCC, then free disk. Both are "the session cannot even
    /// be attempted" answers, which is what `.permissionMissing`'s payload is
    /// for — it is the `checkingPermission` state's generic failure carrier,
    /// not literally a permission-only event.
    private func checkPreflight() {
        refreshPermission()
        switch permissionState {
        case .notDetermined:
            // Shows the system dialog and stamps the request. The answer is
            // false even on a grant (TCC answers for the process as launched),
            // so the honest next step is the "quit and reopen" fault (§2.6).
            ScreenRecordingPermission.request(defaults: defaults)
            refreshPermission()
            perform(apply(.permissionMissing(.permissionNeeded)))
            return
        case .deniedOrStale:
            perform(apply(.permissionMissing(.permissionNeeded)))
            return
        case .granted:
            break
        }

        let dir = recordingsDirectory()
        guard hasEnoughDiskSpace(near: dir) else {
            log.error("screen recording refused — less than \(ScreenRecordingDefaults.minFreeDiskBytes) bytes free")
            perform(apply(.permissionMissing(.diskFull)))
            return
        }

        perform(apply(.permissionOK))
    }

    private func presentPicker() {
        pickTask?.cancel()
        pickTask = Task { @MainActor [weak self] in
            let choice = await RegionPicker().pick()
            guard !Task.isCancelled, let self else { return }
            self.pickTask = nil
            guard let choice else {
                // Esc / ⌘. / focus lost: nothing was started, nothing logged;
                // the pill just sinks back to its backdrop (§7 row 8).
                self.perform(self.apply(.regionCancelled))
                return
            }
            self.pendingChoice = choice
            self.perform(self.apply(.regionPicked))
        }
    }

    private func startCapture() {
        guard let choice = pendingChoice, let since = machine.since else {
            perform(apply(.captureDidNotStart(.captureFailed("No region was chosen."))))
            return
        }

        // Resolved per session, never cached: Settings can move the folder
        // (`DictationController.syncLogStore` makes the same promise).
        let dir = recordingsDirectory()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            log.error("screen recording output folder unusable: \(String(describing: error), privacy: .public)")
            perform(apply(.captureDidNotStart(.outputUnwritable(dir.path))))
            return
        }
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        let outputURL = ScreenRecordingFileNaming.recordingURL(in: dir, date: since, existing: existing)

        let captureMicrophone = resolveMicrophonePermission()
        micDenied = !captureMicrophone
        micGapStart = nil
        micLostAt = nil
        writerFailureMessage = nil
        startFailure = nil

        let target = ScreenRecordingTarget(
            displayID: choice.displayID,
            sourceRect: choice.globalRect.map {
                CaptureGeometry.sourceRect(fromGlobal: $0, displayFrame: choice.displayFrame)
            }
        )
        let recorder = ScreenRecorder(
            configuration: ScreenRecordingConfiguration(
                target: target,
                outputURL: outputURL,
                captureMicrophone: captureMicrophone
            )
        )
        self.recorder = recorder
        observeEvents(of: recorder)

        // The pill shows `.recording` NOW, before the shareable-content
        // snapshot (§2.1 step 5): the whole-app exclusion needs at least one
        // Kleoth window in that snapshot, and the click is acknowledged on the
        // first frame instead of after SCK's startup latency.
        coordinator.setRecordingBackdrop(since: since)

        startTask?.cancel()
        startTask = Task { @MainActor [weak self] in
            do {
                try await recorder.start()
                guard !Task.isCancelled, let self else { return }
                self.startTask = nil
                // A stop arrived while SCK was starting up: the machine has
                // already moved on and `finalize()` owns the rest.
                guard case .starting = self.machine.state else { return }
                self.perform(self.apply(.captureStarted))
                if !captureMicrophone {
                    // §7 row 5: record anyway, say so for 3 s, then the
                    // `.recording` backdrop comes back on its own auto-hide.
                    self.coordinator.showRecordingPhase(
                        .warning("Recording without the microphone — allow it in System Settings")
                    )
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.startTask = nil
                self.log.error("screen recording start failed: \(String(describing: error), privacy: .public)")
                guard case .starting = self.machine.state else {
                    // Stopped mid-start. Dropping the recorder makes
                    // `finalize()` take its "nothing to finalize" branch, which
                    // is the truth: capture never began — but keep WHY so the
                    // fault names the real cause.
                    self.startFailure = Self.failure(for: error)
                    self.recorder = nil
                    return
                }
                self.coordinator.setRecordingBackdrop(since: nil)
                self.perform(self.apply(.captureDidNotStart(Self.failure(for: error))))
            }
        }
    }

    /// The capture is live. The backdrop is already `.recording(since:)` from
    /// `startCapture()`; re-asserting it is free because `since` is fixed for
    /// the session, so the pill compares the state equal and fires no spring
    /// (§6.1).
    private func showRecording() {
        guard let since = machine.since else { return }
        coordinator.setRecordingBackdrop(since: since)
        startLevelPump()
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: "Screen recording started", .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )
    }

    private func stopCapture() {
        guard case .stopping(let reason) = machine.state else { return }
        pendingStopReason = reason
        pickTask?.cancel()
        pickTask = nil
        // `startTask` is deliberately NOT cancelled: cancelling mid-`SCStream`
        // setup would tear down a half-built session behind `ScreenRecorder`'s
        // back. `finalize()` awaits it instead, so `stop()` always sees a
        // settled recorder. It is bounded — `start()` is capped by the
        // shareable-content timeout plus `firstFrameTimeout` — and the quit
        // path replies after `finalizeTimeout` regardless.
        refusalTask?.cancel()
        refusalTask = nil
        // `ScreenRecorder.stop(reason:)` stops the stream AND finalizes in one
        // call, so the machine's two steps collapse: show `.saving` here and go
        // straight on to `.finalize`.
        coordinator.showRecordingPhase(.saving)
        perform(apply(.captureStopped))
    }

    private func finalize() {
        guard let recorder else {
            perform(apply(.finalizeFailed(startFailure ?? .nothingCaptured)))
            return
        }
        let reason = pendingStopReason ?? .user
        finalizeTask?.cancel()
        let pendingStart = startTask
        finalizeTask = Task { @MainActor [weak self] in
            // Never finalize a session whose `start()` is still in flight.
            await pendingStart?.value
            guard let self else { return }
            self.startTask = nil
            guard self.recorder != nil else {
                self.perform(self.apply(.finalizeFailed(self.startFailure ?? .nothingCaptured)))
                return
            }
            do {
                let summary = try await recorder.stop(reason: reason)
                self.finalizeTask = nil
                if reason == .writerFailed, let message = self.writerFailureMessage {
                    // §7 row 13: the fragments are on disk, but this recording
                    // did NOT end the way the user asked it to.
                    self.perform(self.apply(.finalizeFailed(.writerFailed(message))))
                } else {
                    self.perform(self.apply(.finalized(summary)))
                }
            } catch {
                self.finalizeTask = nil
                self.log.error("screen recording finalize failed: \(String(describing: error), privacy: .public)")
                if case ScreenRecorderError.finalizeTimedOut = error {
                    // §7 row 24: the file exists and the launch sweep will
                    // close it out; a sticky red fault would be a lie.
                    self.faultOverride = .warning("Saved with a delay")
                    self.lastStopDetail = "Saving took too long — the file is checked at the next launch"
                }
                self.perform(self.apply(.finalizeFailed(Self.failure(for: error))))
            }
        }
    }

    private func showSaved() {
        guard case .saved(let summary) = machine.state else { return }
        lastSummary = summary
        lastStopDetail = Self.detail(for: summary, micDenied: micDenied)
        // ORDER MATTERS (§6.1), the other way round: drop the backdrop FIRST.
        // `setBackdrop` only takes over a resting-family phase, and `.recording`
        // is one — so with the recording backdrop still on screen (a dictation
        // ended over the top of `.saving`), clearing it AFTER the confirmation
        // would `show(.idle)` on top of the `.saved` transition and eat it.
        // Clearing it first is safe in both directions: on `.saving` the change
        // is merely stored, and on `.recording` the `.saved` shown right after
        // owns the later transition.
        coordinator.setRecordingBackdrop(since: nil)
        if let at = micLostAt {
            // §7 row 16: the file is complete and in `lastSummary`, but the
            // mic went silent partway — that is a warning, not a clean check.
            coordinator.showRecordingPhase(
                .warning("Saved — the microphone dropped out at \(ElapsedFormatter.string(seconds: Int(at)))")
            )
        } else {
            coordinator.showRecordingPhase(.saved(summary.pillText))
        }
        cleanUpSession()
        finishTermination()
        handleFreshRecording(summary)
    }

    private func showFailed() {
        guard case .failed(let failure) = machine.state else { return }
        coordinator.setRecordingBackdrop(since: nil)
        // §7 row 22: a fault raised while a dictation phase is live is dropped
        // from the pill by the coordinator — `lastStopDetail` carries it either
        // way, which is why it is set before the pill is asked.
        if let override = faultOverride {
            // The override's own detail line was set where it was raised.
            faultOverride = nil
            coordinator.showRecordingPhase(override)
        } else {
            lastStopDetail = Self.detail(for: failure)
            coordinator.showRecordingPhase(Self.pillState(for: failure))
        }
        cleanUpSession()
        finishTermination()
    }

    private func resetSession() {
        coordinator.setRecordingBackdrop(since: nil)
        cleanUpSession()
        finishTermination()
    }

    // MARK: - Recorder events

    private func observeEvents(of recorder: ScreenRecorder) {
        eventsTask?.cancel()
        let events = recorder.events
        eventsTask = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: ScreenRecorderEvent) {
        switch event {
        case .firstFrame, .micStarted:
            break
        case .micGapBegan(let at):
            micGapStart = at
        case .micGapEnded(let at):
            defer { micGapStart = nil }
            guard let start = micGapStart else { return }
            let duration = at - start
            guard duration >= ScreenRecordingDefaults.micGapReportThreshold else { return }
            lastStopDetail = String(
                format: "mic dropped for %.1f s at %@",
                duration,
                ElapsedFormatter.string(seconds: Int(start))
            )
        case .micLost(let message):
            log.error("screen recording lost the microphone: \(message, privacy: .public)")
            let at = machine.since.map { Date().timeIntervalSince($0) } ?? 0
            micLostAt = at
            lastStopDetail = "The microphone dropped out at \(ElapsedFormatter.string(seconds: Int(at)))"
        case .streamStopped(let reason, let systemInitiated):
            log.notice("screen recording stream stopped (\(reason, privacy: .public), system: \(systemInitiated))")
            guard systemInitiated else { return }
            // Not a failure: finalize what exists (§2.7).
            requestStop(.systemStoppedStream)
        case .writerFailed(let message):
            log.error("screen recording writer failed: \(message, privacy: .public)")
            writerFailureMessage = message
            requestStop(.writerFailed)
        }
    }

    // MARK: - Pill actions

    private func handlePillAction(_ action: DictationPillAction) {
        switch action {
        case .startScreenRecording:
            start(from: .pill)
        case .stopScreenRecording:
            stop()
        case .revealLastRecording:
            revealLast()
            coordinator.dismissRecordingPhase()
        case .openScreenRecordingSettings:
            if let url = URL(string: ScreenRecordingPermission.settingsURLString) {
                NSWorkspace.shared.open(url)
            }
            coordinator.dismissRecordingPhase()
        case .openSettings, .openAccessibilitySettings,
             .startHandsFreeDictation, .stopHandsFreeDictation, .selectMicrophone,
             .pasteLastDictation, .openDictationHistory, .hideForAnHour:
            // Never routed here — the coordinator sends these to the dictation
            // handler. Listed so the switch stays exhaustive.
            break
        }
    }

    /// §7 row 7: the popover and the pill can both ask at once. Say "already
    /// recording" for a second, then put the recording indicator back — a bare
    /// `.warning` would auto-hide the pill 3 s later while the session is still
    /// running. The `DictationController.refuseWhileBusy` idiom.
    private func refuseAlreadyActive() {
        // Only meaningful once there is something to go back TO: while the
        // picker is up it covers the screen anyway, and `.checkingPermission`
        // is a single synchronous beat.
        guard machine.since != nil, !coordinator.isDictationPhaseLive else { return }
        refusalTask?.cancel()
        coordinator.showRecordingPhase(.warning("Already recording"))
        refusalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.refusalDisplayDuration)
            guard !Task.isCancelled, let self, self.isActive else { return }
            self.refusalTask = nil
            guard let since = self.machine.since else { return }
            self.coordinator.showRecordingPhase(.recording(since: since))
        }
    }

    // MARK: - Stop plumbing

    private func requestStop(_ reason: ScreenRecordingStopReason) {
        perform(apply(.stopRequested(reason)))
    }

    private func cleanUpSession() {
        stopLevelPump()
        pickTask?.cancel(); pickTask = nil
        startTask?.cancel(); startTask = nil
        eventsTask?.cancel(); eventsTask = nil
        refusalTask?.cancel(); refusalTask = nil
        recorder = nil
        pendingChoice = nil
        pendingStopReason = nil
        writerFailureMessage = nil
        startFailure = nil
        micGapStart = nil
        micLostAt = nil
    }

    /// Always replies on a LATER main-queue turn. `beginTerminationStop` can
    /// finish synchronously (quit while the region picker is up tears the
    /// session down with no file), and `NSApp.reply(toApplicationShouldTerminate:)`
    /// must not run before `applicationShouldTerminate` has returned
    /// `.terminateLater`.
    private func finishTermination() {
        terminationTimeoutTask?.cancel()
        terminationTimeoutTask = nil
        guard let completion = terminationCompletion else { return }
        terminationCompletion = nil
        DispatchQueue.main.async { MainActor.assumeIsolated { completion() } }
    }

    // MARK: - Launch sweep

    /// A `*.recording.mp4` at launch means the process died mid-session
    /// (crash, `kill -9`, `kill -TERM` — none of which run either terminate
    /// delegate). A fragmented MP4's completed fragments are playable, so
    /// anything with a real duration is kept under `-recovered.mp4`; a file
    /// that never got a fragment is debris and goes to the Trash. Nothing is
    /// deleted outright (§2.5, §7 row 18).
    private func sweepInterruptedRecordings() async {
        let fileManager = FileManager.default
        let dir = recordingsDirectory()
        guard let names = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return }
        let leftovers = names.filter(ScreenRecordingFileNaming.isInFlightName).sorted()
        guard !leftovers.isEmpty else { return }

        var recovered: ScreenRecordingSummary?
        for name in leftovers {
            let url = dir.appendingPathComponent(name)
            let asset = AVURLAsset(url: url)
            let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            guard seconds.isFinite, seconds > 0 else {
                log.notice("trashing an empty interrupted recording: \(name, privacy: .public)")
                try? fileManager.trashItem(at: url, resultingItemURL: nil)
                continue
            }
            let target = Self.uniqueURL(ScreenRecordingFileNaming.recoveredURL(for: url), fileManager: fileManager)
            do {
                try fileManager.moveItem(at: url, to: target)
            } catch {
                log.error("could not rename an interrupted recording: \(String(describing: error), privacy: .public)")
                continue
            }
            let size = (try? fileManager.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0
            recovered = ScreenRecordingSummary(
                url: target,
                duration: seconds,
                fileSizeBytes: size,
                videoFramesAppended: 0,
                droppedFrames: 0,
                micCaptured: false,
                micGaps: [],
                stopReason: .writerFailed
            )
            log.notice("recovered an interrupted recording: \(target.lastPathComponent, privacy: .public)")
        }

        guard let recovered else { return }
        // Only surface it when the user has not already made a newer recording
        // in this launch (they cannot have — the sweep runs at launch — but the
        // guard keeps the popover row honest if that ever changes).
        if lastSummary == nil {
            lastSummary = recovered
            lastStopDetail = "Recovered a screen recording"
        }
    }

    private static func uniqueURL(_ url: URL, fileManager: FileManager) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var suffix = 2
        while true {
            let candidate = dir.appendingPathComponent("\(stem)-\(suffix)").appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            suffix += 1
        }
    }

    // MARK: - Helpers

    /// `~/Kleoth/screen-recordings` by default. Read fresh every time — never
    /// cached — so moving the output folder in Settings takes effect for the
    /// next recording (§2.5).
    private func recordingsDirectory() -> URL {
        AppConfig.settings().outputDir
            .appendingPathComponent(ScreenRecordingDefaults.directoryName, isDirectory: true)
    }

    /// The target folder may not exist yet, so the volume is probed through the
    /// nearest ancestor that does. An unanswerable volume fails OPEN: refusing
    /// to record because a quirky filesystem does not report capacity would be
    /// worse than running out of space and reporting it (§7 row 13).
    private func hasEnoughDiskSpace(near dir: URL) -> Bool {
        var probe = dir
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        guard let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return true }
        return available >= ScreenRecordingDefaults.minFreeDiskBytes
    }

    /// `.denied` / `.restricted` → record without the microphone (§7 row 5).
    /// `.notDetermined` → ask and carry on: the system dialog is asynchronous
    /// and Core Audio returns zeros while it is up, so `MicrophoneSource`
    /// attaches late, the moment the grant lands (§2.6). Not awaited — the
    /// recording must not wait on a dialog the user may leave open.
    private func resolveMicrophonePermission() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            return false
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return true
        case .authorized:
            return true
        @unknown default:
            return true
        }
    }

    /// `ScreenRecorderError` → the machine's failure vocabulary (§7).
    private static func failure(for error: Error) -> ScreenRecordingFailure {
        guard let error = error as? ScreenRecorderError else {
            return .captureFailed(String(describing: error))
        }
        switch error {
        case .userDeclined, .noFirstFrame:
            return .permissionStale
        case .noDisplay:
            return .noDisplay
        case .shareableContentTimedOut:
            return .captureFailed("Screen Recording did not respond — try again after allowing it")
        case .selfNotInShareableContent:
            return .captureFailed("Couldn't hide Kleoth's own windows from the recording — try again")
        case .nothingCaptured:
            return .nothingCaptured
        case .alreadyStarted:
            return .alreadyActive
        case .finalizeTimedOut:
            return .writerFailed("finalize timed out")
        case .writerSetupFailed(let message), .writerFailed(let message):
            return .writerFailed(message)
        }
    }

    /// The pill state one failure produces. Every `.message` is capped at
    /// `DictationPillFault.maxMessageLength` by the fault itself; the full text
    /// goes to the log.
    private static func pillState(for failure: ScreenRecordingFailure) -> DictationPillState {
        switch failure {
        case .permissionNeeded: return .failed(.screenRecordingNeeded)
        case .permissionStale: return .failed(.screenRecordingStale)
        case .noDisplay: return .failed(.message("That display is no longer available."))
        case .diskFull: return .failed(.message("Not enough free disk space to record"))
        case .alreadyActive: return .warning("Already recording")
        case .outputUnwritable(let path): return .failed(.message("Can't write to \(path)"))
        case .captureFailed(let message): return .failed(.message(message))
        case .writerFailed(let message): return .failed(.message("Recording failed: \(message)"))
        case .nothingCaptured: return .failed(.message("Nothing was recorded."))
        }
    }

    private static func detail(for failure: ScreenRecordingFailure) -> String? {
        switch failure {
        case .permissionStale: return "Screen Recording needs a relaunch"
        case .permissionNeeded: return "Screen Recording is not allowed"
        case .diskFull: return "Not enough free disk space"
        case .nothingCaptured: return "Nothing was recorded"
        case .noDisplay, .alreadyActive, .outputUnwritable, .captureFailed, .writerFailed:
            return nil
        }
    }

    /// The popover's one-line "what was odd about that recording" (§2.5).
    private static func detail(for summary: ScreenRecordingSummary, micDenied: Bool) -> String? {
        switch summary.stopReason {
        case .systemStoppedStream, .displayLost:
            return "Stopped: the display disconnected"
        case .user, .quit, .writerFailed:
            break
        }
        if micDenied || !summary.micCaptured {
            return micDenied ? "No microphone (permission denied)" : "No microphone"
        }
        if let gap = summary.micGaps
            .filter({ $0.duration >= ScreenRecordingDefaults.micGapReportThreshold })
            .max(by: { $0.duration < $1.duration }) {
            return String(
                format: "mic dropped for %.1f s at %@",
                gap.duration,
                ElapsedFormatter.string(seconds: Int(gap.at))
            )
        }
        return nil
    }
}
