import Testing
import Foundation
@testable import KleothCore

@Suite struct ProviderDetectorTests {
    static func probes(
        local: @escaping @Sendable (URL) async -> Result<[String], Error> = { _ in .failure(URLError(.cannotConnectToHost)) },
        claude: @escaping @Sendable () async -> ProviderAvailability = { .unavailable(reason: "Not installed") },
        codex: @escaping @Sendable () async -> ProviderAvailability = { .unavailable(reason: "Not installed") },
        apple: @escaping @Sendable () async -> ProviderAvailability = { .unavailable(reason: "Needs macOS 26") }
    ) -> ProviderDetector.Probes {
        ProviderDetector.Probes(localServer: local, claudeCode: claude, codex: codex, apple: apple)
    }

    @Test func snapshotCoversEveryProvider() async {
        let detector = ProviderDetector(probes: Self.probes(
            local: { _ in .success(["llama3", "qwen3"]) },
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
        let detector = ProviderDetector(probes: Self.probes(local: { _ in
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

    @Test func localModelListDecodesTheOpenAIShape() async throws {
        let transport = MockTransport(json: #"{"object":"list","data":[{"id":"llama3:8b","object":"model"},{"id":"qwen3","object":"model"}]}"#)
        let models = try await LocalModelList.fetch(baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: nil, transport: transport)
        #expect(models == ["llama3:8b", "qwen3"])
        #expect(transport.recordedRequests[0].url?.absoluteString == "http://localhost:11434/v1/models")
    }

    actor Counter {
        var value = 0
        func bump() { value += 1 }
    }
}
