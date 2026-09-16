import Testing
import Foundation
@testable import KleothCore

@Suite struct ProviderDetectorTests {
    static func probes(
        local: @escaping @Sendable (URL, String?) async -> Result<[String], Error> = { _, _ in .failure(URLError(.cannotConnectToHost)) },
        claude: @escaping @Sendable () async -> ProviderAvailability = { .unavailable(reason: "Not installed") },
        codex: @escaping @Sendable () async -> ProviderAvailability = { .unavailable(reason: "Not installed") },
        apple: @escaping @Sendable () async -> ProviderAvailability = { .unavailable(reason: "Needs macOS 26") }
    ) -> ProviderDetector.Probes {
        ProviderDetector.Probes(localServer: local, claudeCode: claude, codex: codex, apple: apple)
    }

    @Test func snapshotCoversEveryProvider() async {
        let detector = ProviderDetector(probes: Self.probes(
            local: { _, _ in .success(["llama3", "qwen3"]) },
            claude: { .available(detail: "Claude Code 2.1.272 · signed in") }))
        let snap = await detector.snapshot(settings: ProviderSettings(), openRouterKey: "test-key")
        #expect(snap.count == AIProvider.allCases.count)
        #expect(snap[.localServer] == .available(detail: "localhost:11434 · 2 models", models: ["llama3", "qwen3"]))
        #expect(snap[.claudeCode] == .available(detail: "Claude Code 2.1.272 · signed in"))
        #expect(snap[.codex] == .unavailable(reason: "Not installed"))
        #expect(snap[.openRouter] == .available(detail: "API key set"))
        #expect(snap[.appleOnDevice] == .unavailable(reason: "Needs macOS 26"))
    }

    @Test func noKeyAndNoServer() async {
        let detector = ProviderDetector(probes: Self.probes())
        let snap = await detector.snapshot(settings: ProviderSettings(), openRouterKey: nil)
        #expect(snap[.openRouter] == .unavailable(reason: "No API key"))
        #expect(snap[.localServer] == .unavailable(reason: "No server at http://localhost:11434"))
    }

    @Test func snapshotIsCachedUntilRefreshOrInputChange() async {
        let counter = Counter()
        let detector = ProviderDetector(probes: Self.probes(local: { _, _ in
            await counter.bump()
            return .success(["m"])
        }))
        _ = await detector.snapshot(settings: ProviderSettings(), openRouterKey: nil)
        _ = await detector.snapshot(settings: ProviderSettings(), openRouterKey: nil)
        #expect(await counter.value == 1)
        var other = ProviderSettings()
        other.localServerURL = URL(string: "http://localhost:1234/v1")!
        _ = await detector.snapshot(settings: other, openRouterKey: nil)
        #expect(await counter.value == 2)
        await detector.refresh()
        _ = await detector.snapshot(settings: other, openRouterKey: nil)
        #expect(await counter.value == 3)
    }

    @Test func localProbeReceivesTheServerKey() async {
        let recorder = KeyRecorder()
        let detector = ProviderDetector(probes: Self.probes(local: { _, key in
            await recorder.record(key)
            return .success([])
        }))
        var withKey = ProviderSettings()
        withKey.localServerKey = "test-key"
        _ = await detector.snapshot(settings: withKey, openRouterKey: nil)
        #expect(await recorder.lastKey == "test-key")

        var withoutKey = ProviderSettings()
        withoutKey.localServerKey = nil
        _ = await detector.snapshot(settings: withoutKey, openRouterKey: nil)
        #expect(await recorder.lastKey == nil)
    }

    @Test func changingTheLocalKeyInvalidatesTheCache() async {
        let counter = Counter()
        let detector = ProviderDetector(probes: Self.probes(local: { _, _ in
            await counter.bump()
            return .success(["m"])
        }))
        var withKeyA = ProviderSettings()
        withKeyA.localServerKey = "key-a"
        _ = await detector.snapshot(settings: withKeyA, openRouterKey: nil)
        #expect(await counter.value == 1)

        var withKeyB = ProviderSettings()
        withKeyB.localServerKey = "key-b"
        _ = await detector.snapshot(settings: withKeyB, openRouterKey: nil)
        #expect(await counter.value == 2)
    }

    @Test func localModelListDecodesTheOpenAIShape() async throws {
        let transport = MockTransport(json: #"{"object":"list","data":[{"id":"llama3:8b","object":"model"},{"id":"qwen3","object":"model"}]}"#)
        let models = try await LocalModelList.fetch(baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: nil, transport: transport)
        #expect(models == ["llama3:8b", "qwen3"])
        #expect(transport.recordedRequests[0].url?.absoluteString == "http://localhost:11434/v1/models")
    }

    /// A snapshot gathered while the calling task was cancelled is full of
    /// false negatives — the process runner terminates the child and throws,
    /// the transport throws `URLError(.cancelled)`, and each probe converts
    /// that into "Did not answer" / "No server at …". Caching one would pin
    /// those verdicts for the whole TTL, so `snapshot` returns it without
    /// storing it.
    @Test func cancelledSnapshotIsNotCached() async {
        let counter = Counter()
        let detector = ProviderDetector(probes: Self.probes(local: { _, _ in
            await counter.bump()
            try? await Task.sleep(for: .milliseconds(300))
            return .success(["m"])
        }))
        let task = Task { await detector.snapshot(settings: ProviderSettings(), openRouterKey: nil) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = await task.value
        #expect(await counter.value == 1)
        // Nothing was cached, so this must probe again rather than serve the
        // cancelled result.
        _ = await detector.snapshot(settings: ProviderSettings(), openRouterKey: nil)
        #expect(await counter.value == 2)
    }

    /// `Probes.standard`'s local-server probe must not inherit the shared
    /// `URLSessionTransport`'s `waitsForConnectivity = true` (tuned for long
    /// Scribe uploads) — that silently ignores a short request timeout and
    /// can hang for days on a refused connection. Port 1 is always closed, so
    /// this must fail fast with `.failure`, well under the 10 s ceiling every
    /// other probe uses and far under a hang.
    @Test func localProbeFailsFastWhenNothingListens() async throws {
        let probes = ProviderDetector.Probes.standard(
            locator: ToolLocator(searchDirectories: []),
            runner: MockProcessRunner(stdout: ""),
            transport: URLSessionTransport())
        let started = Date()
        let result = await probes.localServer(URL(string: "http://127.0.0.1:1/v1")!, nil)
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 3)
        guard case .failure = result else {
            Issue.record("expected .failure, got \(result)")
            return
        }
    }

    /// `codex login status` prints "Logged in using ChatGPT" to stderr, not
    /// stdout (verified live) — the probe must still read it as signed in.
    @Test func codexProbeReadsLoggedInFromStderr() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-codex-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let exe = root.appendingPathComponent("codex")
        try Data("#!/bin/sh\n".utf8).write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        let runner = MockProcessRunner(results: [
            .success(ProcessResult(stdout: Data("codex-cli 0.153.4".utf8), stderr: Data(), status: 0)),
            .success(ProcessResult(stdout: Data(), stderr: Data("Logged in using ChatGPT\n".utf8), status: 0)),
        ])
        let probes = ProviderDetector.Probes.standard(
            locator: ToolLocator(searchDirectories: [root]),
            runner: runner,
            transport: URLSessionTransport())
        let result = await probes.codex()
        #expect(result == .available(detail: "Codex 0.153.4 · signed in"))
    }

    actor Counter {
        var value = 0
        func bump() { value += 1 }
    }

    actor KeyRecorder {
        var lastKey: String?
        func record(_ key: String?) { lastKey = key }
    }
}
