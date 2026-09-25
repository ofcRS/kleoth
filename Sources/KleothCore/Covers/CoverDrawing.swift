import Foundation

/// One meeting's cover, start to finish (design doc 2026-09-24 §3.2 "Order",
/// §3.4, §4.1, §5): the summary → the scene step → the image engine → a
/// normalized `cover.jpg` and its `cover.json`.
///
/// The app and `kleoth illustrate` both draw through this, so the budget, the
/// retry rule, the sensitive skip and the History wording are the same
/// wherever a cover is drawn. It never touches `meta.json` and never marks the
/// meeting as processing: a cover is decoration, and a failure leaves the
/// meeting — and any cover it already has — exactly as it was.
public struct CoverDrawing: Sendable {
    /// What to draw, and with what.
    public struct Request: Sendable, Equatable {
        public var meetingDir: URL
        public var engine: CoverEngine
        /// The image model, as sent; empty for Codex, which uses its own tool.
        public var model: String
        /// Settings' fixed style or New Cover ▸'s pick; nil lets the scene
        /// step choose by the meeting's mood.
        public var fixedStyle: CoverStyle?

        public init(meetingDir: URL, engine: CoverEngine, model: String, fixedStyle: CoverStyle?) {
            self.meetingDir = meetingDir
            self.engine = engine
            self.model = model
            self.fixedStyle = fixedStyle
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// A picture was installed; the record is what `cover.json` now says.
        case drawn(CoverRecord)
        /// The scene step judged the meeting personal, so no image call was
        /// made. The record is on disk unless the meeting already had a
        /// picture: a New Cover that comes back sensitive changes nothing (§5).
        case skipped(CoverRecord)
    }

    /// The History line's fixed start; `message(for:engine:)` adds the reason.
    public static let failurePrefix = "Couldn't draw a cover — "

    /// Seconds the scene step may take (measured at 2–12 s). It exists
    /// because the scene step's transport may wait for connectivity:
    /// `URLSessionTransport()` waits for a network with a 1,200 s request
    /// timeout, so a scene on OpenRouter with the Wi-Fi off would spin until
    /// the network came back and hold up the cloud queue. The app and the CLI
    /// now give the scene call `CoverEngineFactory.cloudTransport`, which
    /// fails at once offline; this budget still bounds a stalled network and a
    /// CLI backend that never answers. The step is not retried — the retry
    /// covers only the image call — so a hang reads "Timed out after 60 s".
    public static let sceneBudget: TimeInterval = 60

    public let sceneWriter: CoverSceneWriter
    /// Who writes the scene, recorded as `scene_provider`.
    public let sceneProvider: AIProvider
    public let generator: any CoverImageGenerating
    public let store: CoverStore
    /// The pause before the one retry of a transient image failure (2 s; 0 in tests).
    public let retryDelay: TimeInterval
    public let now: @Sendable () -> Date
    /// Moves a replaced picture to the Trash (`FileManager.trashItem` in the
    /// app and the CLI), injected so tests never touch the real Trash.
    public let trash: @Sendable (URL) throws -> Void
    /// Tests only: replaces `sceneBudget` (60 s) and `engine.budget` (90–300 s)
    /// with something a test can wait for. nil in production.
    public var budgetOverride: TimeInterval?

    public init(
        sceneWriter: CoverSceneWriter, sceneProvider: AIProvider, generator: any CoverImageGenerating,
        store: CoverStore = .init(), retryDelay: TimeInterval = 2,
        now: @escaping @Sendable () -> Date = Date.init, trash: @escaping @Sendable (URL) throws -> Void
    ) {
        self.sceneWriter = sceneWriter
        self.sceneProvider = sceneProvider
        self.generator = generator
        self.store = store
        self.retryDelay = retryDelay
        self.now = now
        self.trash = trash
    }

    // MARK: - Drawing

    /// Writes the scene, then either records a sensitive skip or draws,
    /// normalizes and installs the picture (the previous one goes to the Trash).
    ///
    /// The scene step runs once under `sceneBudget`. Each image attempt runs
    /// under `engine.budget`; a transient failure (`isTransient`) gets
    /// `engine.retries` more tries after `retryDelay`.
    /// On New Cover the previous scene goes to the scene step so the new
    /// picture shows a different idea.
    ///
    /// Throws `CoverError.noSummary` before any call when there is no
    /// summary; otherwise the scene step's, the engine's or the store's error
    /// (`CoverStoreError.meetingFolderMissing` for a meeting deleted
    /// mid-draw). Nothing is written until the picture is in hand, so a
    /// failed scene or image leaves the meeting as it was. A cancellation is
    /// rethrown as it arrived — never retried, never wrapped — and any other
    /// error that arrives once the task is cancelled, in the scene step or the
    /// image step, becomes `CancellationError`, so the app can tell Covers →
    /// Off from a failure and show no error line for it.
    public func draw(_ request: Request) async throws -> Outcome {
        let dir = request.meetingDir
        let (title, summary) = try Self.loadInputs(meetingDir: dir)
        let existing = store.record(in: dir)
        // Only a drawn record has a scene worth steering away from.
        let previousScene = existing?.state == .drawn ? existing?.scene : nil
        let scene: CoverScene
        let sceneCost: Double
        let sceneWriter = self.sceneWriter
        let fixedStyle = request.fixedStyle
        do {
            // One attempt under `sceneBudget`; a `KleothTimeoutError` here is
            // final (the retry loop is the image step's alone).
            (scene, sceneCost) = try await withTimeout(seconds: budgetOverride ?? Self.sceneBudget) {
                try await sceneWriter.write(
                    title: title, summary: summary, fixedStyle: fixedStyle, previousScene: previousScene
                )
            }
        } catch {
            // The image step's rule: a backend whose call was torn down by
            // the cancel may report an ordinary failure; the cancel wins.
            if DictationTranscription.isCancellation(error) { throw error }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()

        if scene.sensitive {
            let record = CoverRecord(
                state: .skipped, reason: "sensitive", sceneProvider: sceneProvider.rawValue,
                sceneModel: sceneWriter.model, createdAt: CoverRecord.timestamp(now()),
                cost: sceneCost > 0 ? sceneCost : nil
            )
            // A picture already on disk stays what it is, record and all: a
            // New Cover that came back sensitive changes nothing (§3.5, §5).
            if store.imageURL(in: dir) == nil { try store.writeRecord(record, in: dir) }
            return .skipped(record)
        }

        let started = ContinuousClock.now
        let image = try await generate(
            prompt: CoverPrompt.imagePrompt(scene: scene.scene, style: scene.style), request: request
        )
        let seconds = Self.seconds(since: started)
        let jpeg = try CoverImageFile.normalize(image.data)
        let total = (image.cost ?? 0) + sceneCost
        let record = CoverRecord(
            state: .drawn, engine: request.engine.rawValue, model: request.model, style: scene.style.rawValue,
            scene: scene.scene, sceneProvider: sceneProvider.rawValue, sceneModel: sceneWriter.model,
            createdAt: CoverRecord.timestamp(now()), cost: total > 0 ? total : nil, seconds: seconds
        )
        // Covers → Off while the picture was being normalized: still nothing written.
        try Task.checkCancellation()
        try store.install(jpeg: jpeg, record: record, in: dir, trash: trash)
        return .drawn(record)
    }

    /// The scene step's inputs, read the same way by `draw` and by
    /// `kleoth illustrate --dry-run`. Throws `CoverError.noSummary` when
    /// `summary.json` is missing or unreadable: the scene is never written
    /// from the transcript.
    ///
    /// The title is the summary's own (trimmed, non-empty) first — the
    /// model's specific name for the meeting, which the look test drew from —
    /// then `meta.json`'s, which may still be a placeholder such as
    /// "Meeting 2026-09-24", then the folder name.
    public static func loadInputs(meetingDir: URL) throws -> (title: String, summary: MeetingSummary) {
        let meetings = MeetingStore(baseDir: meetingDir.deletingLastPathComponent())
        guard let summary = try? meetings.loadSummary(in: meetingDir) else { throw CoverError.noSummary }
        let title = nonBlank(summary.title)
            ?? nonBlank((try? meetings.loadMetadata(in: meetingDir))?.title)
            ?? meetingDir.lastPathComponent
        return (title, summary)
    }

    // MARK: - Failures

    /// Worth one more try after `retryDelay`: timeouts (the budget's own
    /// `KleothTimeoutError` and URLSession's `URLError(.timedOut)`), network
    /// trouble, HTTP 408 / 429 / 5xx. Never a cancellation, a rejected key or
    /// request, a refusal, or bytes that did not decode — those fail the same
    /// way twice. A local server that refuses the connection arrives as
    /// `ProviderError.unreachable` and is not transient either: a server that
    /// is not running will not have started 2 s later.
    public static func isTransient(_ error: any Error) -> Bool {
        switch error {
        case is KleothTimeoutError:
            return true
        case is URLError:
            return DictationTranscription.isTransient(error)
        case let CoverError.http(status, _):
            return isTransientStatus(status)
        case let OpenRouterError.httpError(status, _):
            return isTransientStatus(status)
        default:
            return false
        }
    }

    /// The words after `failurePrefix` (the History line) and after
    /// `failed —` (the CLI) — §5's matrix. `engine` matters because a status
    /// code means different things: a 401 from OpenRouter is a bad key, from
    /// a local server it is only that server's answer, and "no image" from
    /// Codex means its own tool drew nothing. The provider layer's errors keep
    /// the provider layer's copy, so a missing tool, a signed-out CLI or a
    /// stopped Ollama read the same here as they do for summaries.
    public static func reason(for error: any Error, engine: CoverEngine? = nil) -> String {
        switch error {
        case let timeout as KleothTimeoutError:
            return "Timed out after \(Int(timeout.seconds.rounded())) s"
        case is URLError:
            // Its `cause` never names Scribe; the detail sentence does.
            return DictationTranscription.summary(of: error, attempts: 1).cause
        case let cover as CoverError:
            return reason(for: cover, engine: engine)
        case let OpenRouterError.httpError(status, _):
            // Only the scene step throws this (the image clients throw
            // `CoverError.http`), and `OpenAICompatibleClient` throws it for a
            // local scene server too: its own copy would name OpenRouter and
            // carry the raw body, so the line names neither.
            return "The scene model answered HTTP \(status)"
        case is CocoaError:
            // A failed write or Trash move in `install` (disk full, a folder
            // that can't be written). Foundation throws these as `NSError`s,
            // which are no `LocalizedError`, so `default` would print
            // "Error Domain=NSCocoaErrorDomain Code=… UserInfo={…}". Only this
            // domain: a plain Swift error's `localizedDescription` is "The
            // operation couldn't be completed. (… error 0.)", worse than `default`.
            return error.localizedDescription
        default:
            return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    /// `failurePrefix` + `reason(for:engine:)`: the whole History line.
    public static func message(for error: any Error, engine: CoverEngine? = nil) -> String {
        failurePrefix + reason(for: error, engine: engine)
    }

    // MARK: - Private

    /// One attempt per budget, plus `engine.retries` after a transient failure.
    private func generate(prompt: String, request: Request) async throws -> GeneratedImage {
        let generator = self.generator
        let model = request.model
        let attempts = 1 + request.engine.retries
        let budget = budgetOverride ?? request.engine.budget
        var attempt = 1
        while true {
            do {
                let image = try await withTimeout(seconds: budget) {
                    try await generator.generate(prompt: prompt, model: model)
                }
                try Task.checkCancellation()
                return image
            } catch {
                if DictationTranscription.isCancellation(error) { throw error }
                // Cancelled while the attempt failed for another reason (the
                // budget fired in the same instant): the cancel wins.
                if Task.isCancelled { throw CancellationError() }
                guard attempt < attempts, Self.isTransient(error) else { throw error }
            }
            attempt += 1
            if retryDelay > 0 { try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000)) }
        }
    }

    private static func reason(for error: CoverError, engine: CoverEngine?) -> String {
        switch (error, engine) {
        case let (.http(status, _), .localServer?):
            return "The local server answered HTTP \(status)"
        case let (.http(status, _), .openRouter?), let (.http(status, _), nil):
            switch status {
            case 401: return "OpenRouter rejected the key"
            case 402: return "Out of OpenRouter credits"
            case 429: return "OpenRouter is busy (HTTP 429)"
            case 500...599: return "OpenRouter error \(status)"
            default: return "HTTP \(status)"
            }
        case (.noImage, .codex?):
            return "Codex didn't draw an image"
        default:
            return error.errorDescription ?? String(describing: error)
        }
    }

    private static func isTransientStatus(_ status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let elapsed = start.duration(to: .now)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
