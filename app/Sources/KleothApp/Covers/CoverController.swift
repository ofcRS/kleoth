import Foundation
import KleothCore
import os

/// Draws meeting covers in the background (design doc 2026-09-24 §3.2, §4.4,
/// §5): the automatic hook after a summary is saved, History's Draw Cover /
/// New Cover / Try Again / Remove Cover, and Covers → Off. `@MainActor`,
/// app-lifetime `shared` — the `RecordingController` / `DictationController`
/// shape, so `RecordingController`'s summary saves can reach it without a view.
///
/// A cover is decoration, so this controller never touches the meeting's own
/// state: it never marks a meeting as processing (rename, re-transcribe,
/// Remove Transcription and delete stay available), writes no status line and
/// posts no notification. A failure shows only on the meeting page's cover
/// chip and at the top of the cover menu, from `failures`, which is memory only.
///
/// Two queues, one per kind of cost:
/// - a local-server cover joins `RecordingController`'s pipeline queue,
///   because two heavy local models (WhisperKit and the image model) must
///   never run at once;
/// - Codex and OpenRouter covers run one at a time on this controller's own
///   `Task` chain (the `pipelineQueueTail` idiom), so they never delay a
///   transcription.
///
/// `generation` is what makes Covers → Off stick for jobs this controller
/// cannot reach: a job queued before `cancelAll()` finds a newer generation
/// when its turn comes and does nothing. A job that is already running is
/// cancelled through its handle in `jobs`.
@MainActor
final class CoverController: ObservableObject {
    private(set) static var shared: CoverController?

    /// The current engine; nil = Off: nothing can be drawn, and views hide
    /// every cover surface but the pictures a demo launch shows (`showsCovers`).
    @Published private(set) var engine: CoverEngine?
    /// Whether History shows any cover surface: an engine is picked, or this
    /// is a demo launch. A demo launch keeps Covers Off (`AppConfig` forces
    /// it) so nothing can be drawn — `enqueue` needs an engine and
    /// `AppConfig.makeSceneWriter()` throws — but the pictures its data folder
    /// holds are shown, so the films can show the page as it looks with them.
    var showsCovers: Bool { engine != nil || DemoMode.isOn }
    /// Standardized meeting paths with a cover job queued or running — the
    /// spinner on the row tile, the page chip and the band. Not
    /// `processingPaths`: a cover never blocks the meeting.
    @Published private(set) var busyPaths: Set<String> = []
    /// Standardized meeting path → the §5 line ("Couldn't draw a cover — …").
    /// Memory only: a relaunch forgets every failure, which is the point — a
    /// cover is decoration, not a task the user owes anything.
    @Published private(set) var failures: [String: String] = [:]
    /// Bumped on every install / skip / remove, so a view showing a meeting's
    /// `cover.json` (the tooltip, the "Skipped" line) re-reads it.
    @Published private(set) var revision: Int = 0

    /// The last link of the Codex / OpenRouter chain. Each new job awaits it
    /// before running, so cloud covers run strictly one at a time within a
    /// generation. After Off → On, a cancelled job already past its last
    /// cancellation check may still finish its install while the new chain
    /// starts. That is bounded and harmless: the later install trashes the
    /// earlier picture. So the chains are not serialised across generations.
    private var cloudQueueTail: Task<Void, Never>?
    /// Bumped by `cancelAll()`. A job carries the generation it was queued in
    /// and runs, or cleans up after itself, only while that is still current.
    private var generation = 0
    /// The running job's handle per standardized path, for `cancelAll()`. A
    /// queued job has no entry yet: the generation check stops it instead.
    private var jobs: [String: Task<Void, Never>] = [:]
    private let store = CoverStore()
    private let log = Logger(subsystem: "dev.kleoth", category: "Covers")

    init() {
        engine = AppConfig.settings().coverSettings.engine
        Self.shared = self
    }

    // MARK: - Settings

    /// Re-reads the engine after any cover setting is written
    /// (`RecordingController.updateCover…`). Off hides every cover surface;
    /// cancelling the jobs is `cancelAll()`'s, which the Off setter calls
    /// first so the views never show Off while a job still runs.
    func settingsChanged() {
        engine = AppConfig.settings().coverSettings.engine
    }

    // MARK: - Launch

    /// Removes stale `.cover-*.tmp` files (a kill mid-install leaves one; design
    /// §10) from every meeting folder, once, off the main actor. Called from
    /// `AppDelegate.applicationDidFinishLaunching`, so a demo launch — which
    /// has no `AppDelegate` — never deletes anything. Files younger than
    /// `CoverStore.temporaryFileMaxAge` stay: `kleoth illustrate` may be
    /// drawing into that folder right now. Only `meeting-*` folders are
    /// visited: a cover is only ever installed in one.
    func sweepTemporaryFilesAtLaunch() {
        let outputDir = AppConfig.settings().outputDir
        let store = self.store
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let folders = try? fm.contentsOfDirectory(
                at: outputDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { return }
            var removed = 0
            for folder in folders
            where folder.lastPathComponent.hasPrefix("meeting-")
                && (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                removed += store.sweepTemporaryFiles(in: folder).count
            }
            if removed > 0 {
                Logger(subsystem: "dev.kleoth", category: "Covers")
                    .notice("swept \(removed, privacy: .public) stale cover temp files")
            }
        }
    }

    // MARK: - Drawing

    /// The automatic hook, called by `RecordingController` right after a
    /// summary is saved (§3.2). It draws only for a meeting with a summary and
    /// neither a picture nor a `cover.json`, so a re-summary never replaces a
    /// cover, and a removed or skipped cover is never redrawn behind the
    /// user's back.
    func summaryWritten(in dir: URL) {
        let settings = AppConfig.settings().coverSettings
        guard settings.engine != nil, settings.automatic, store.isEligibleForAutomaticCover(in: dir) else { return }
        enqueue(dir: dir, style: .settings)
    }

    /// Draw Cover(s), New Cover and Try Again. Draw Cover and Try Again pass
    /// `.settings`. New Cover ▸ passes its pick, `.automatic` or `.fixed`,
    /// which wins over the Style setting (`CoverStyleChoice`). A meeting that
    /// already has a job queued or running is left alone.
    func draw(_ meetings: [RecentMeeting], style: CoverStyleChoice = .settings) {
        for meeting in meetings {
            enqueue(dir: meeting.directory, style: style)
        }
    }

    /// Remove Cover: the picture goes to the Trash and `cover.json` records
    /// `removed`, so no cover is drawn automatically again (§3.5). Runs
    /// inline: two file moves are not worth a queue.
    func remove(_ meeting: RecentMeeting) {
        // No engine = Covers Off, which a demo launch forces: its data folder is never written.
        guard engine != nil else { return }
        let dir = meeting.directory
        let path = key(dir)
        do {
            try store.remove(in: dir, now: Date()) { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
            revision &+= 1
            failures[path] = nil
            RecordingController.shared?.coverChanged(in: dir)
        } catch {
            failures[path] = CoverDrawing.message(for: error)
            log.error("remove failed in \(dir.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Covers → Off (§3.2, §5 "Covers → Off mid-draw"): every running job is
    /// cancelled, and every queued one finds a newer generation when its turn
    /// comes and does nothing. The cloud chain starts afresh; its stale links
    /// still unwind one by one, each doing nothing. Failure lines stay: they
    /// are hidden while Off and still true when covers come back.
    func cancelAll() {
        generation += 1
        jobs.values.forEach { $0.cancel() }
        jobs = [:]
        cloudQueueTail = nil
        busyPaths = []
    }

    // MARK: - Reading

    /// The meeting's `cover.json`, read fresh. A view that calls this from
    /// `body` re-reads it on every publish: its `@EnvironmentObject`
    /// observation re-runs `body`, and an install, skip or remove publishes.
    func record(for dir: URL) -> CoverRecord? {
        store.record(in: dir)
    }

    func isBusy(_ dir: URL) -> Bool {
        busyPaths.contains(key(dir))
    }

    func failure(for dir: URL) -> String? {
        failures[key(dir)]
    }

    /// A deleted meeting: drop its failure line, and cancel a running job for
    /// it so a trashed meeting doesn't cost one more paid call. No generation
    /// bump: the job is still current, so `runJob` cleans up after it as
    /// usual, and `fail()` shows nothing for a cancelled job. A job still
    /// queued for it runs later and fails silently on the missing folder.
    func forget(_ dir: URL) {
        let path = key(dir)
        failures[path] = nil
        jobs[path]?.cancel()
    }

    // MARK: - Private

    /// The one spelling of a meeting's path for `busyPaths`, `failures` and
    /// `jobs`, so a meeting reached through two URL spellings is one entry
    /// (the `processingPaths` convention).
    private func key(_ dir: URL) -> String {
        dir.standardizedFileURL.path
    }

    /// Queues one cover for `dir` on the engine's queue (see the type's doc).
    /// The engine is fixed here. The model and the Style setting (for
    /// `.settings`) are read when the job runs, so an edit made while it
    /// waits applies to it.
    private func enqueue(dir: URL, style: CoverStyleChoice) {
        guard let engine else { return }
        let path = key(dir)
        guard !busyPaths.contains(path) else { return }
        let gen = generation
        if engine == .localServer {
            guard let queue = RecordingController.shared else {
                log.error("no RecordingController to queue a local cover on")
                return
            }
            busyPaths.insert(path)
            queue.enqueuePipelineJob { [weak self] in
                await self?.runJob(dir: dir, style: style, engine: engine, generation: gen)
            }
        } else {
            busyPaths.insert(path)
            let previous = cloudQueueTail
            cloudQueueTail = Task { [weak self] in
                await previous?.value
                await self?.runJob(dir: dir, style: style, engine: engine, generation: gen)
            }
        }
    }

    /// One job's turn on its queue. The work runs in a `Task` of its own so
    /// `cancelAll()` has a handle to cancel: the pipeline queue's link belongs
    /// to `RecordingController`, and cancelling a cloud link would not reach
    /// the work it awaits. The queue waits for that task, so a cancelled job
    /// still holds its place until it has unwound.
    ///
    /// Both exits clean up only while `gen` is still current. `cancelAll()`
    /// already emptied `busyPaths` and `jobs`; after it, the user may turn
    /// covers back on and draw the same meeting before this job has unwound.
    /// A stale job that cleared `jobs[path]` and `busyPaths` then would erase
    /// the new job's handle and busy flag — the new job could no longer be
    /// cancelled, and the same meeting could be queued twice.
    private func runJob(dir: URL, style: CoverStyleChoice, engine: CoverEngine, generation gen: Int) async {
        guard generation == gen else { return }   // queued before Covers → Off
        let path = key(dir)
        let task = Task<Void, Never> { [weak self] in
            await self?.perform(dir: dir, style: style, engine: engine)
        }
        jobs[path] = task
        await task.value
        if generation == gen {
            jobs[path] = nil
            busyPaths.remove(path)
        }
    }

    /// Resolves the scene writer and the image engine, then draws. Every
    /// failure becomes the meeting's cover line (the page chip and the menu)
    /// through `fail(_:in:error:)`; the copy is §5's, from
    /// `CoverDrawing.message(for:engine:)`, except the one line that names no
    /// engine because no scene could be written at all.
    private func perform(dir: URL, style: CoverStyleChoice, engine: CoverEngine) async {
        // Cancelled before it started (Covers → Off right after `runJob`
        // made it): leave the failure line to whichever job is current.
        guard !Task.isCancelled else { return }
        failures[key(dir)] = nil

        let writer: CoverSceneWriter
        let selection: ProviderFactory.Selection
        do {
            (writer, selection) = try await AppConfig.makeSceneWriter()
        } catch {
            fail(CoverDrawing.failurePrefix + "No AI provider for the scene (\(error.localizedDescription))", in: dir, error: error)
            return
        }
        let generator: any CoverImageGenerating
        do {
            generator = try AppConfig.coverEngineFactory().generator(for: engine)
        } catch {
            fail(CoverDrawing.message(for: error, engine: engine), in: dir, error: error)
            return
        }
        let settings = AppConfig.settings().coverSettings
        let request = CoverDrawing.Request(
            meetingDir: dir, engine: engine, model: settings.model(for: engine),
            fixedStyle: style.fixedStyle(settingsStyle: settings.style)
        )
        let drawing = CoverDrawing(
            sceneWriter: writer, sceneProvider: selection.provider, generator: generator,
            trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
        )
        do {
            // `CoverDrawing.draw` is a nonisolated async function on a Sendable
            // value: it runs off the main actor for its whole length (network
            // waits, ImageIO), and this actor only sees the outcome. (That holds
            // while the packages leave `NonisolatedNonsendingByDefault` off.)
            let outcome = try await drawing.draw(request)
            // Written even when cancelled meanwhile: the files changed, so
            // the list and the page must say so.
            revision &+= 1
            RecordingController.shared?.coverChanged(in: dir)
            switch outcome {
            case .drawn(let record):
                log.notice("drew \(record.engine ?? "", privacy: .public) cover in \(dir.lastPathComponent, privacy: .public)")
            case .skipped:
                log.notice("skipped (sensitive) \(dir.lastPathComponent, privacy: .public)")
            }
        } catch {
            if DictationTranscription.isCancellation(error) { return }   // Covers → Off, or quit
            fail(CoverDrawing.message(for: error, engine: engine), in: dir, error: error)
        }
    }

    /// Pins `line` on `dir`'s cover chip and menu and logs `error` — unless
    /// the job was cancelled (Covers → Off: §5 shows nothing, and a stale line
    /// must not land on a job queued after it) or the meeting is gone (deleted
    /// mid-draw: "a deleted meeting shows nothing", and `forget` has already
    /// dropped its line). The log names the error's type `.public`, so
    /// `log stream` shows a reason class, and keeps the §5 line and the full
    /// error `.private`: the line can carry a CLI's verbatim message or raw
    /// output (`ProviderError.backend`), which may echo a scene written from
    /// the summary. `String(describing:)`, not `localizedDescription`: the
    /// details `CoverError` keeps "for the log only" (`.sceneUnreadable`'s
    /// answer, `.refused`'s and `.http`'s response body) appear only there.
    /// No error in the chain carries a key (the key goes only in the
    /// request's header).
    private func fail(_ line: String, in dir: URL, error: any Error) {
        guard !Task.isCancelled else { return }
        log.error("cover failed in \(dir.lastPathComponent, privacy: .public): \(String(describing: type(of: error)), privacy: .public) · \(line, privacy: .private) · \(String(describing: error), privacy: .private)")
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        failures[key(dir)] = line
    }
}
