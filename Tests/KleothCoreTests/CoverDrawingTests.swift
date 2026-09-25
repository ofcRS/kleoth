import Foundation
import Testing
@testable import KleothCore

/// An image engine that replays a script, so the drawing under test never
/// knows it is not OpenRouter, a local server or Codex. Counts every call and
/// remembers what each one asked for.
private final class StubGenerator: CoverImageGenerating, @unchecked Sendable {
    enum Step {
        case image(Data, cost: Double? = nil)
        case fail(any Error)
        /// Sleeps far past any test budget — only the budget or a cancel ends it.
        case hang
    }

    /// The script ran out: the drawing called more often than the test allows.
    struct Exhausted: Error {}
    /// A hang that nothing ended; not transient, so a test relying on the budget fails.
    struct NeverInterrupted: Error {}

    private let lock = NSLock()
    private var steps: [Step]
    private var requests: [(prompt: String, model: String)] = []

    init(_ steps: [Step]) {
        self.steps = steps
    }

    var calls: Int { lock.withLock { requests.count } }
    var prompts: [String] { lock.withLock { requests.map(\.prompt) } }
    var models: [String] { lock.withLock { requests.map(\.model) } }

    func generate(prompt: String, model: String) async throws -> GeneratedImage {
        let step = lock.withLock { () -> Step? in
            requests.append((prompt, model))
            return steps.isEmpty ? nil : steps.removeFirst()
        }
        switch step {
        case let .image(data, cost)?:
            return GeneratedImage(data: data, cost: cost)
        case let .fail(error)?:
            throw error
        case .hang?:
            try await Task.sleep(nanoseconds: 30_000_000_000)
            throw NeverInterrupted()
        case nil:
            throw Exhausted()
        }
    }
}

/// A scene backend that answers only once the drawing is cancelled, and then
/// with an ordinary failure — the way a CLI child killed mid-call reports
/// itself — so a test can see whether the cancel or that error wins.
private final class InterruptedSceneClient: ChatCompleting, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false

    var hasStarted: Bool { lock.withLock { started } }

    func complete(
        messages: [ChatMessage], model: String, responseFormat: OpenRouterResponseFormat,
        maxTokens: Int, temperature: Double?, reasoning: OpenRouterReasoning?
    ) async throws -> ChatCompletion {
        lock.withLock { started = true }
        // The sleep's own CancellationError is swallowed on purpose: the
        // backend's error below is what reaches the drawing.
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        throw ProviderError.backend("The scene call was interrupted.")
    }
}

/// A scene backend that never answers, the way the default transport waits
/// for connectivity with the Wi-Fi off. Its sleep is cooperative, so only the
/// scene budget or a cancel ends it.
private final class HangingSceneClient: ChatCompleting, @unchecked Sendable {
    /// The hour ran out: nothing ended the hang.
    struct NeverInterrupted: Error {}

    private let lock = NSLock()
    private var started = false

    var hasStarted: Bool { lock.withLock { started } }

    func complete(
        messages: [ChatMessage], model: String, responseFormat: OpenRouterResponseFormat,
        maxTokens: Int, temperature: Double?, reasoning: OpenRouterReasoning?
    ) async throws -> ChatCompletion {
        lock.withLock { started = true }
        try await Task.sleep(nanoseconds: 3_600_000_000_000)
        throw NeverInterrupted()
    }
}

/// The drawing (design doc 2026-09-24 §3.2 "Order", §3.4 "Retries"/"Budgets",
/// §4.1, §5): summary → scene → image → `cover.jpg` + `cover.json`, with the
/// engine's budget and retry rule, and the History line for every failure.
@Suite struct CoverDrawingTests {
    private let good = #"{"sensitive":false,"style":"sketch","scene":"Two otters stack pebbles."}"#
    private let sensitive = #"{"sensitive":true,"style":"sketch","scene":""}"#
    private let png = CoverTestImages.png(width: 64, height: 64)
    private let now: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_790_000_000) }
    private let store = CoverStore()

    // MARK: - Helpers

    /// `<tmp>/kleoth-cover-drawing-tests-<uuid>/meeting-2026-09-24-100000/`
    /// with a meeting-shaped `meta.json` and, unless `summary` is false, a
    /// `summary.json`.
    private func makeMeeting(summary: Bool = true) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-cover-drawing-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("meeting-2026-09-24-100000", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // `participants` and `consent_acknowledged` are required by
        // `MeetingMetadata`'s decoder, and every real `meta.json` has them.
        try write(
            #"{"title":"Launch plan","date":"2026-09-24","participants":[],"consent_acknowledged":false}"#,
            "meta.json", in: dir
        )
        if summary {
            try write(
                #"{"tldr":"We planned the launch.","overview":"Lots of detail.","action_items":[],"per_speaker_highlights":[]}"#,
                "summary.json", in: dir
            )
        }
        return dir
    }

    private func removeRoot(of dir: URL) {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func write(_ text: String, _ name: String, in dir: URL) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    private func read(_ name: String, in dir: URL) throws -> String {
        String(decoding: try Data(contentsOf: dir.appendingPathComponent(name)), as: UTF8.self)
    }

    private func exists(_ name: String, in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    /// The scene step's canned answer; `cost` is what the backend reports (only OpenRouter does).
    private func sceneClient(_ answer: String, cost: Double? = nil) -> MockChatClient {
        MockChatClient(results: [.success(ChatCompletion(
            content: answer, usage: cost.map { ChatUsage(cost: $0) }, finishReason: "stop"
        ))])
    }

    private func drawing(
        client: any ChatCompleting, generator: StubGenerator, retryDelay: TimeInterval = 0,
        trash: RecordingTrash = RecordingTrash()
    ) -> CoverDrawing {
        CoverDrawing(
            sceneWriter: CoverSceneWriter(client: client, model: "sonnet"), sceneProvider: .claudeCode,
            generator: generator, retryDelay: retryDelay, now: now, trash: { try trash($0) }
        )
    }

    private func request(_ dir: URL, engine: CoverEngine = .openRouter, model: String = "m") -> CoverDrawing.Request {
        CoverDrawing.Request(meetingDir: dir, engine: engine, model: model, fixedStyle: nil)
    }

    private func drawnRecord(scene: String = "an owl reads") -> CoverRecord {
        CoverRecord(
            state: .drawn, engine: "openrouter", model: "m", style: "clay", scene: scene,
            sceneProvider: "claude-code", sceneModel: "sonnet", createdAt: "2026-09-20T10:00:00Z", cost: 0.03
        )
    }

    /// Polls (bounded) until `condition` holds, so a test acts at a known
    /// point instead of after a guessed sleep.
    private func waitUntil(
        _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<1_000 where !condition() {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        if !condition() { Issue.record("condition never held", sourceLocation: sourceLocation) }
    }

    // MARK: - Drawing

    @Test func happyPathInstallsTheCoverAndADrawnRecord() async throws {
        let dir = try makeMeeting()
        defer { removeRoot(of: dir) }
        let client = sceneClient(good, cost: 0.0002)
        let generator = StubGenerator([.image(png, cost: 0.03)])

        let outcome = try await drawing(client: client, generator: generator).draw(request(dir))

        guard case let .drawn(record) = outcome else {
            Issue.record("expected .drawn, got \(outcome)")
            return
        }
        let jpeg = try Data(contentsOf: dir.appendingPathComponent("cover.jpg"))
        let size = try #require(CoverImageFile.pixelSize(of: jpeg))
        #expect(size.width == 64 && size.height == 64)
        #expect(record.state == .drawn)
        #expect(record.engine == "openrouter")
        #expect(record.model == "m")
        #expect(record.style == "sketch")
        #expect(record.scene == "Two otters stack pebbles.")
        #expect(record.sceneProvider == "claude-code")
        #expect(record.sceneModel == "sonnet")
        #expect(record.createdAt == CoverRecord.timestamp(now()))
        #expect(abs(try #require(record.cost) - 0.0302) < 1e-9)
        #expect(record.seconds != nil)
        #expect(store.record(in: dir) == record)
        // The engine got exactly the settled prompt for this scene, and the model as picked.
        #expect(generator.prompts == [CoverPrompt.imagePrompt(scene: "Two otters stack pebbles.", style: .sketch)])
        #expect(generator.models == ["m"])
    }

    @Test func sensitiveSkipsAndNeverCallsTheGenerator() async throws {
        let dir = try makeMeeting()
        defer { removeRoot(of: dir) }
        let generator = StubGenerator([.image(png)])

        let outcome = try await drawing(client: sceneClient(sensitive), generator: generator).draw(request(dir))

        guard case let .skipped(record) = outcome else {
            Issue.record("expected .skipped, got \(outcome)")
            return
        }
        #expect(record.state == .skipped)
        #expect(record.reason == "sensitive")
        #expect(record.engine == nil)
        #expect(record.sceneProvider == "claude-code")
        #expect(record.cost == nil)
        #expect(generator.calls == 0)
        #expect(store.record(in: dir) == record)
        #expect(!exists("cover.jpg", in: dir))
    }

    /// §5: a failed New Cover changes nothing, and a sensitive answer is one.
    @Test func sensitiveOnAMeetingWithAPictureWritesNothing() async throws {
        let dir = try makeMeeting()
        defer { removeRoot(of: dir) }
        try write("old", "cover.jpg", in: dir)
        let old = drawnRecord()
        try store.writeRecord(old, in: dir)
        let generator = StubGenerator([.image(png)])

        let outcome = try await drawing(client: sceneClient(sensitive), generator: generator).draw(request(dir))

        guard case .skipped = outcome else {
            Issue.record("expected .skipped, got \(outcome)")
            return
        }
        #expect(try read("cover.jpg", in: dir) == "old")
        #expect(store.record(in: dir) == old)
        #expect(generator.calls == 0)
    }

    @Test func oneTransientFailureIsRetriedOnce() async throws {
        let dir = try makeMeeting()
        defer { removeRoot(of: dir) }
        let recovers = StubGenerator([.fail(CoverError.http(status: 503, body: "")), .image(png)])

        let outcome = try await drawing(client: sceneClient(good), generator: recovers).draw(request(dir))

        guard case .drawn = outcome else {
            Issue.record("expected .drawn, got \(outcome)")
            return
        }
        #expect(recovers.calls == 2)

        let second = try makeMeeting()
        defer { removeRoot(of: second) }
        let failsTwice = StubGenerator([.fail(URLError(.timedOut)), .fail(URLError(.timedOut))])

        let error = await #expect(throws: URLError.self) {
            _ = try await drawing(client: sceneClient(good), generator: failsTwice).draw(request(second))
        }
        #expect(error?.code == .timedOut)
        #expect(failsTwice.calls == 2)
        #expect(!exists("cover.jpg", in: second))
        #expect(!exists("cover.json", in: second))
    }

    @Test func nonTransientFailureDoesNotRetryAndKeepsTheOldCover() async throws {
        let dir = try makeMeeting()
        defer { removeRoot(of: dir) }
        try write("old", "cover.jpg", in: dir)
        let generator = StubGenerator([.fail(CoverError.http(status: 401, body: "")), .image(png)])
        let trash = RecordingTrash()

        await #expect(throws: CoverError.http(status: 401, body: "")) {
            _ = try await drawing(client: sceneClient(good), generator: generator, trash: trash).draw(request(dir))
        }
        #expect(generator.calls == 1)
        #expect(try read("cover.jpg", in: dir) == "old")
        #expect(trash.trashed.isEmpty)
        #expect(!exists("cover.json", in: dir))
    }

    @Test func codexNeverRetries() async throws {
        let dir = try makeMeeting()
        defer { removeRoot(of: dir) }
        let generator = StubGenerator([.fail(KleothTimeoutError(seconds: 1)), .image(png)])

        await #expect(throws: KleothTimeoutError.self) {
            _ = try await drawing(client: sceneClient(good), generator: generator)
                .draw(request(dir, engine: .codex, model: ""))
        }
        #expect(generator.calls == 1)
    }

    /// The hung first call can only end by the budget (its own sleep is 30 s
    /// and then fails non-transiently), so a drawn cover proves the budget
    /// fired and counted as transient.
    @Test func theBudgetFiringIsARetry() async throws {
        let dir = try makeMeeting()
        defer { removeRoot(of: dir) }
        let generator = StubGenerator([.hang, .image(png)])
        var drawing = drawing(client: sceneClient(good), generator: generator)
        drawing.budgetOverride = 0.05

        let outcome = try await drawing.draw(request(dir))

        guard case .drawn = outcome else {
            Issue.record("expected .drawn, got \(outcome)")
            return
        }
        #expect(generator.calls == 2)
    }

    /// Covers → Off mid-draw: the job is cancelled and nothing is written.
    @Test func cancellationIsRethrownUnwrapped() async throws {
        let dir = try makeMeeting()
        defer { removeRoot(of: dir) }
        let generator = StubGenerator([.hang, .image(png)])
        var configured = drawing(client: sceneClient(good), generator: generator)
        configured.budgetOverride = 30
        let drawing = configured
        let request = request(dir)

        let task = Task { try await drawing.draw(request) }
        // Cancel while the image call hangs, not before it starts.
        try await waitUntil { generator.calls == 1 }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(generator.calls == 1)
        #expect(!exists("cover.jpg", in: dir))
        #expect(!exists("cover.json", in: dir))
    }

    /// Covers → Off while the scene is being written: the backend reports its
    /// torn-down call as an ordinary failure, and the cancel still wins, as it
    /// does in the image step, so the app shows no error line for it.
    @Test func cancellationDuringTheSceneStepWins() async throws {
        let dir = try makeMeeting()
        defer { removeRoot(of: dir) }
        let client = InterruptedSceneClient()
        let generator = StubGenerator([.image(png)])
        let drawing = drawing(client: client, generator: generator)
        let request = request(dir)

        let task = Task { try await drawing.draw(request) }
        // Cancel while the scene call waits, not before it starts.
        try await waitUntil { client.hasStarted }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(generator.calls == 0)
        #expect(!exists("cover.jpg", in: dir))
        #expect(!exists("cover.json", in: dir))
    }

    /// A scene call that never answers (OpenRouter with the Wi-Fi off) ends at
    /// the scene budget, is not retried, and never reaches the image engine.
    /// The outer 10 s `withTimeout` is only a safety net: without the scene
    /// budget the hang would hold the suite for an hour, and its own error
    /// (10 s, not 0.05 s) fails the match below.
    @Test func aHungSceneStepTimesOutAtTheSceneBudget() async throws {
        #expect(CoverDrawing.sceneBudget == 60)
        let dir = try makeMeeting()
        defer { removeRoot(of: dir) }
        let client = HangingSceneClient()
        let generator = StubGenerator([.image(png)])
        var configured = drawing(client: client, generator: generator)
        configured.budgetOverride = 0.05
        let drawing = configured
        let request = request(dir)

        await #expect(throws: KleothTimeoutError(seconds: 0.05)) {
            _ = try await withTimeout(seconds: 10) { try await drawing.draw(request) }
        }
        #expect(client.hasStarted)
        #expect(generator.calls == 0)
        #expect(!exists("cover.jpg", in: dir))
        #expect(!exists("cover.json", in: dir))
    }

    /// Offline, with the scene on the fail-fast transport: the scene call's
    /// `URLError` is thrown as it arrived — not retried, even though the image
    /// step would count it as transient — and reads §5's "No internet connection".
    @Test func anOfflineSceneStepReadsNoInternetConnection() async throws {
        let dir = try makeMeeting()
        defer { removeRoot(of: dir) }
        let offline = URLError(.notConnectedToInternet)
        // A retry would get the good answer and draw.
        let client = MockChatClient(results: [
            .failure(offline),
            .success(ChatCompletion(content: good, usage: nil, finishReason: "stop")),
        ])
        let generator = StubGenerator([.image(png)])

        let error = await #expect(throws: URLError.self) {
            _ = try await drawing(client: client, generator: generator).draw(request(dir))
        }
        #expect(error?.code == .notConnectedToInternet)
        #expect(client.calls.count == 1)
        #expect(generator.calls == 0)
        #expect(CoverDrawing.message(for: try #require(error)) == "Couldn't draw a cover — No internet connection")
        #expect(!exists("cover.json", in: dir))
    }

    /// Covers → Off while the scene call hangs under its budget: the cancel
    /// still reaches the call through `withTimeout`, and nothing is written.
    @Test func cancellingAHungSceneStepIsACancellation() async throws {
        let dir = try makeMeeting()
        defer { removeRoot(of: dir) }
        let client = HangingSceneClient()
        let generator = StubGenerator([.image(png)])
        let drawing = drawing(client: client, generator: generator)
        let request = request(dir)

        let task = Task { try await drawing.draw(request) }
        // Cancel while the scene call hangs, not before it starts.
        try await waitUntil { client.hasStarted }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(generator.calls == 0)
        #expect(!exists("cover.jpg", in: dir))
        #expect(!exists("cover.json", in: dir))
    }

    @Test func noSummaryThrowsNoSummary() async throws {
        let dir = try makeMeeting(summary: false)
        defer { removeRoot(of: dir) }
        let client = sceneClient(good)
        let generator = StubGenerator([.image(png)])

        await #expect(throws: CoverError.noSummary) {
            _ = try await drawing(client: client, generator: generator).draw(request(dir))
        }
        #expect(client.calls.isEmpty)
        #expect(generator.calls == 0)
    }

    @Test func previousSceneIsPassedOnANewCover() async throws {
        let dir = try makeMeeting()
        defer { removeRoot(of: dir) }
        try write("old", "cover.jpg", in: dir)
        try store.writeRecord(drawnRecord(scene: "an owl reads"), in: dir)
        let client = sceneClient(good)

        _ = try await drawing(client: client, generator: StubGenerator([.image(png)])).draw(request(dir))

        let user = try #require(client.calls.first?.messages.last?.content)
        #expect(user.contains("Previous scene: an owl reads"))

        let removed = try makeMeeting()
        defer { removeRoot(of: removed) }
        try store.writeRecord(
            CoverRecord(state: .removed, scene: "an owl reads", createdAt: "2026-09-20T10:00:00Z"), in: removed
        )
        let second = sceneClient(good)

        _ = try await drawing(client: second, generator: StubGenerator([.image(png)])).draw(request(removed))

        let secondUser = try #require(second.calls.first?.messages.last?.content)
        #expect(!secondUser.contains("Previous scene"))
    }

    @Test func unreadableImageBytesFail() async throws {
        let dir = try makeMeeting()
        defer { removeRoot(of: dir) }
        let generator = StubGenerator([.image(Data("junk".utf8)), .image(png)])

        await #expect(throws: CoverError.unreadableImage) {
            _ = try await drawing(client: sceneClient(good), generator: generator).draw(request(dir))
        }
        #expect(generator.calls == 1)
        #expect(!exists("cover.jpg", in: dir))
        #expect(!exists("cover.json", in: dir))
    }

    // MARK: - Inputs

    /// The summary's own title first (the model's specific name for the
    /// meeting, as the look test ran it), then `meta.json`'s, then the folder.
    @Test func titleComesFromTheSummaryThenTheMetaThenTheFolder() throws {
        let dir = try makeMeeting()
        defer { removeRoot(of: dir) }
        #expect(try CoverDrawing.loadInputs(meetingDir: dir).title == "Launch plan")
        #expect(try CoverDrawing.loadInputs(meetingDir: dir).summary.tldr == "We planned the launch.")

        try write(#"{"title":"Q3 pricing","tldr":"We priced Q3."}"#, "summary.json", in: dir)
        #expect(try CoverDrawing.loadInputs(meetingDir: dir).title == "Q3 pricing")

        try write(#"{"title":"   ","tldr":"We priced Q3."}"#, "summary.json", in: dir)
        #expect(try CoverDrawing.loadInputs(meetingDir: dir).title == "Launch plan")

        try FileManager.default.removeItem(at: dir.appendingPathComponent("meta.json"))
        #expect(try CoverDrawing.loadInputs(meetingDir: dir).title == "meeting-2026-09-24-100000")

        try write("not json", "summary.json", in: dir)
        #expect(throws: CoverError.noSummary) { _ = try CoverDrawing.loadInputs(meetingDir: dir) }
    }

    @Test func theSceneStepGetsTheTitle() async throws {
        let dir = try makeMeeting()
        defer { removeRoot(of: dir) }
        try write(#"{"title":"Q3 pricing","tldr":"We priced Q3."}"#, "summary.json", in: dir)
        let client = sceneClient(good)

        _ = try await drawing(client: client, generator: StubGenerator([.image(png)])).draw(request(dir))

        let user = try #require(client.calls.first?.messages.last?.content)
        #expect(user.contains("Title: Q3 pricing"))
        #expect(!user.contains("Launch plan"))
    }

    // MARK: - The History line

    @Test func messagesFollowTheErrorMatrix() {
        func message(_ error: any Error, _ engine: CoverEngine? = nil) -> String {
            CoverDrawing.message(for: error, engine: engine)
        }
        let prefix = "Couldn't draw a cover — "
        #expect(CoverDrawing.failurePrefix == prefix)

        #expect(message(CoverError.http(status: 401, body: "")) == prefix + "OpenRouter rejected the key")
        #expect(message(CoverError.http(status: 402, body: "")) == prefix + "Out of OpenRouter credits")
        #expect(message(CoverError.http(status: 429, body: "")) == prefix + "OpenRouter is busy (HTTP 429)")
        #expect(message(CoverError.http(status: 503, body: "")) == prefix + "OpenRouter error 503")
        #expect(message(CoverError.http(status: 401, body: ""), .openRouter) == prefix + "OpenRouter rejected the key")
        #expect(message(CoverError.http(status: 500, body: ""), .localServer)
            == prefix + "The local server answered HTTP 500")
        #expect(message(CoverError.http(status: 401, body: ""), .localServer)
            == prefix + "The local server answered HTTP 401")
        #expect(message(CoverError.dataPolicy(model: "m"))
            == prefix + "OpenRouter's data policy on this account allows no endpoint for m — pick another image model in Settings → Meetings")
        #expect(message(CoverError.refused("x")) == prefix + "The image model refused this scene — try New Cover")
        #expect(message(CoverError.sceneUnreadable("x")) == prefix + "The scene came back unreadable")
        // The scene step's HTTP failure: the same error type whether the scene
        // came from OpenRouter or a local server, so the line names neither
        // and never carries the body.
        #expect(message(OpenRouterError.httpError(status: 503, bodySnippet: "<html>busy</html>"))
            == prefix + "The scene model answered HTTP 503")
        #expect(message(OpenRouterError.httpError(status: 401, bodySnippet: "{\"error\":\"x\"}"), .localServer)
            == prefix + "The scene model answered HTTP 401")
        #expect(message(CoverError.unreadableImage) == prefix + "The image model returned an unreadable image")
        #expect(message(CoverError.noImage, .codex) == prefix + "Codex didn't draw an image")
        #expect(message(CoverError.noImage) == prefix + "The image model returned no image")
        #expect(message(ProviderError.unreachable(url: URL(string: "http://localhost:11434/v1")!))
            == prefix + "No server at http://localhost:11434 — is Ollama running?")
        #expect(message(ProviderError.modelMissing(model: "x/flux2-klein", hint: "ollama pull x/flux2-klein"))
            == prefix + "Model 'x/flux2-klein' is not on the local server — run `ollama pull x/flux2-klein`.")
        #expect(message(ProviderError.notSignedIn(tool: "Codex"))
            == prefix + "Codex is not signed in. Open a terminal, run `codex login`, and sign in.")
        #expect(message(ProviderError.backend("You've hit your usage limit.")) == prefix + "You've hit your usage limit.")
        #expect(message(URLError(.notConnectedToInternet)) == prefix + "No internet connection")
        #expect(message(KleothTimeoutError(seconds: 90)) == prefix + "Timed out after 90 s")
        // A write that fails in `install` (disk full, a Trash move that fails on
        // New Cover): Foundation's errors are no `LocalizedError`, and their
        // `String(describing:)` is "Error Domain=NSCocoaErrorDomain Code=… UserInfo={…}".
        let outOfSpace = CocoaError(.fileWriteOutOfSpace)
        #expect(message(outOfSpace) == prefix + outOfSpace.localizedDescription)
        #expect(!message(outOfSpace).contains("NSCocoaErrorDomain"))
        // What Foundation actually throws at runtime: a bare `NSError` in the Cocoa domain.
        let thrown = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteOutOfSpace.rawValue)
        #expect(message(thrown) == prefix + thrown.localizedDescription)
        #expect(!message(thrown).contains("NSCocoaErrorDomain"))
    }

    @Test func isTransientTable() {
        let transient: [any Error] = [
            KleothTimeoutError(seconds: 90),
            URLError(.timedOut),
            URLError(.networkConnectionLost),
            CoverError.http(status: 408, body: ""),
            CoverError.http(status: 429, body: ""),
            CoverError.http(status: 500, body: ""),
            CoverError.http(status: 503, body: ""),
            OpenRouterError.httpError(status: 502, bodySnippet: ""),
        ]
        for error in transient {
            #expect(CoverDrawing.isTransient(error), "\(error) should be transient")
        }

        let final: [any Error] = [
            URLError(.cancelled),
            CancellationError(),
            CoverError.http(status: 400, body: ""),
            CoverError.http(status: 401, body: ""),
            CoverError.http(status: 402, body: ""),
            CoverError.http(status: 404, body: ""),
            CoverError.refused("x"),
            CoverError.dataPolicy(model: "m"),
            CoverError.unreadableImage,
            ProviderError.unreachable(url: URL(string: "http://localhost:11434/v1")!),
            ProviderError.timedOut,
            ProviderError.backend("x"),
        ]
        for error in final {
            #expect(!CoverDrawing.isTransient(error), "\(error) should not be transient")
        }
    }
}
