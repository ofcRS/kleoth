import Testing
import Foundation
@testable import KleothCore

@Suite struct CoverEngineFactoryTests {
    static let nowhere = ToolLocator(searchDirectories: [URL(fileURLWithPath: "/nonexistent")])

    static func factory(
        key: String? = nil, localURL: String? = nil, localKey: String? = nil,
        locator: ToolLocator = nowhere,
        cloud: MockTransport = MockTransport(json: "{}"), local: MockTransport = MockTransport(json: "{}")
    ) -> CoverEngineFactory {
        var config: [String: String] = [:]
        config["local_server_url"] = localURL
        config["local_server_key"] = localKey
        return CoverEngineFactory(
            settings: Settings.load(config: config), credentials: Credentials(openRouterKey: key),
            runner: MockProcessRunner(stdout: ""), locator: locator,
            cloudTransport: cloud, localTransport: local)
    }

    @Test func openRouterWithoutAKeyIsNoProvider() throws {
        #expect(throws: ProviderError.noProvider) { _ = try Self.factory(key: nil).generator(for: .openRouter) }
        #expect(throws: ProviderError.noProvider) { _ = try Self.factory(key: "").generator(for: .openRouter) }

        let cloud = MockTransport(json: "{}")
        let generator = try Self.factory(key: "k", cloud: cloud).generator(for: .openRouter)
        let client = try #require(generator as? ImageGenerationClient)
        #expect(client.dialect == .openRouter)
        #expect(client.baseURL == OpenRouterClient.baseURL)
        #expect(client.apiKey == "k")
        #expect((client.transport as? MockTransport) === cloud)
    }

    @Test func noCodexIsNotInstalled() throws {
        #expect(throws: ProviderError.notInstalled(tool: "Codex")) { _ = try Self.factory().generator(for: .codex) }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-cover-factory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let codex = dir.appendingPathComponent("codex")
        try Data("#!/bin/sh\n".utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        let generator = try Self.factory(locator: ToolLocator(searchDirectories: [dir])).generator(for: .codex)
        let client = try #require(generator as? CodexImageClient)
        #expect(client.executable == codex)
        #expect(client.timeout == 240)
        #expect(client.codexHome == CoverEngineFactory.codexHome)
        #expect(client.scratchDirectory == CoverEngineFactory.codexScratchDirectory)
        #expect(client.environment["PATH"]?.isEmpty == false)
    }

    @Test func localUsesTheServerURLAndKey() throws {
        let cloud = MockTransport(json: "{}")
        let local = MockTransport(json: "{}")
        let factory = Self.factory(key: "k", localURL: "http://box:1234/v1", localKey: "t", cloud: cloud, local: local)
        let client = try #require(try factory.generator(for: .localServer) as? ImageGenerationClient)
        #expect(client.dialect == .openAICompatible)
        #expect(client.baseURL.absoluteString == "http://box:1234/v1")
        #expect(client.apiKey == "t")
        // The local server's bounded session, never the cloud one.
        #expect((client.transport as? MockTransport) === local)
        #expect((client.transport as? MockTransport) !== cloud)
    }

    /// A local server with nothing listening must fail in a second, not wait
    /// for connectivity; a cold image-model load still gets minutes.
    @Test func localTransportIsBoundedAndEphemeral() {
        let configuration = CoverEngineFactory.localTransport.session.configuration
        #expect(configuration.waitsForConnectivity == false)
        #expect(configuration.timeoutIntervalForRequest == 300)
        #expect(configuration.timeoutIntervalForResource == 600)
    }

    /// OpenRouter with the Wi-Fi off must fail at once ("No internet
    /// connection"), not wait for connectivity until the 90 s budget fires
    /// twice; both limits sit above that budget, so the budget fires first.
    @Test func cloudTransportFailsFastOffline() {
        let configuration = CoverEngineFactory.cloudTransport.session.configuration
        #expect(configuration.waitsForConnectivity == false)
        #expect(configuration.timeoutIntervalForRequest == 100)
        #expect(configuration.timeoutIntervalForResource == 120)
        #expect(configuration.timeoutIntervalForRequest > CoverEngine.openRouter.budget)
    }
}
