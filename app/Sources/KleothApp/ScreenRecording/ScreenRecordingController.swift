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
        }
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
        case .openSettings, .openAccessibilitySettings:
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
