import Testing
import Foundation
@testable import KleothCore

@Suite struct ProviderFactoryTests {
    static func factory(settings: ProviderSettings = ProviderSettings(), key: String? = nil) -> ProviderFactory {
        ProviderFactory(
            settings: settings, openRouterKey: key, transport: MockTransport(json: "{}"),
            runner: MockProcessRunner(stdout: ""),
            locator: ToolLocator(searchDirectories: [URL(fileURLWithPath: "/nonexistent")]),
            appleClient: nil)
    }

    static func snapshot(_ entries: ProviderSnapshot) -> ProviderSnapshot {
        var snap: ProviderSnapshot = [:]
        for provider in AIProvider.allCases { snap[provider] = entries[provider] ?? .unavailable(reason: "Not installed") }
        return snap
    }

    @Test func selectUsesTheStoredOrDefaultModel() throws {
        var settings = ProviderSettings()
        settings = settings.settingModel("opus", for: .summary, on: .claudeCode)
        let factory = Self.factory(settings: settings)
        let snap = Self.snapshot([.claudeCode: .available(detail: "ok")])
        let selection = try factory.select(task: .summary, snapshot: snap).get()
        #expect(selection == ProviderFactory.Selection(provider: .claudeCode, model: "opus", fellThroughFrom: nil))
        let dictation = try factory.select(task: .dictation, snapshot: snap).get()
        #expect(dictation.model == "haiku")
    }

    @Test func localServerDefaultsToItsFirstModel() throws {
        let factory = Self.factory()
        let snap = Self.snapshot([.localServer: .available(detail: "x", models: ["qwen3", "llama3"])])
        #expect(try factory.select(task: .summary, snapshot: snap).get().model == "qwen3")
        let empty = Self.snapshot([.localServer: .available(detail: "x", models: [])])
        #expect(factory.select(task: .summary, snapshot: empty)
                == .failure(.backend("The local server lists no models — run `ollama pull <model>` first.")))
    }

    @Test func nothingAvailableIsNoProvider() {
        #expect(Self.factory().select(task: .summary, snapshot: Self.snapshot([:])) == .failure(.noProvider))
    }

    @Test func unavailableExplicitPickMapsToTheRightError() {
        var settings = ProviderSettings()
        settings.pick = .claudeCode
        let notInstalled = Self.factory(settings: settings)
        #expect(notInstalled.select(task: .summary, snapshot: Self.snapshot([:])) == .failure(.notInstalled(tool: "Claude Code")))
        let notSignedIn = Self.snapshot([.claudeCode: .unavailable(reason: "Not signed in")])
        #expect(notInstalled.select(task: .summary, snapshot: notSignedIn) == .failure(.notSignedIn(tool: "Claude Code")))
        settings.pick = .localServer
        let down = Self.factory(settings: settings)
        #expect(down.select(task: .summary, snapshot: Self.snapshot([:]))
                == .failure(.unreachable(url: ProviderSettings.defaultLocalServerURL)))
    }

    @Test func clientsAreBuiltPerProvider() throws {
        let factory = Self.factory(key: "test-key")
        #expect(try factory.client(for: .openRouter) is OpenRouterClient)
        #expect(try factory.client(for: .localServer) is OpenAICompatibleClient)
        #expect(throws: ProviderError.notInstalled(tool: "Claude Code")) { _ = try factory.client(for: .claudeCode) }
        #expect(throws: ProviderError.notInstalled(tool: "Codex")) { _ = try factory.client(for: .codex) }
        #expect(throws: ProviderError.unsupported("Apple on-device is not available.")) { _ = try factory.client(for: .appleOnDevice) }
        let noKey = Self.factory()
        #expect(throws: ProviderError.noProvider) { _ = try noKey.client(for: .openRouter) }
    }

    /// The local server must fail fast when nothing is listening, so it gets
    /// its own bounded session instead of the caller's upload-tuned transport
    /// (20 min between bytes, `waitsForConnectivity`). OpenRouter keeps the
    /// injected one.
    @Test func localServerGetsItsOwnBoundedSession() throws {
        let factory = Self.factory(key: "test-key")
        let local = try #require(try factory.client(for: .localServer) as? OpenAICompatibleClient)
        #expect(!(local.transport is MockTransport))
        let session = try #require((local.transport as? URLSessionTransport)?.session)
        #expect(session.configuration.waitsForConnectivity == false)
        #expect(session.configuration.timeoutIntervalForRequest == 120)
        #expect(session.configuration.timeoutIntervalForResource == 600)
        let router = try #require(try factory.client(for: .openRouter) as? OpenRouterClient)
        #expect(router.transport is MockTransport)
    }

    @Test func polisherFallbackModelOnlyOnOpenRouter() throws {
        let factory = Self.factory(key: "test-key")
        let router = try factory.polisher(for: .init(provider: .openRouter, model: "m", fellThroughFrom: nil))
        #expect(router.fallbackModel == DictationDefaults.fallbackPolishModel)
        #expect(router.model == "m")
        let local = try factory.polisher(for: .init(provider: .localServer, model: "qwen3", fellThroughFrom: nil))
        #expect(local.fallbackModel == nil)
        let summarizer = try factory.summarizer(for: .init(provider: .localServer, model: "qwen3", fellThroughFrom: nil))
        #expect(summarizer.model == "qwen3")
    }
}
