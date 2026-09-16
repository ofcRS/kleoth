import Testing
import Foundation
@testable import KleothCore

@Suite struct ProviderSettingsTests {
    @Test func defaultsWhenNothingIsConfigured() {
        let settings = ProviderSettings.load(config: [:])
        #expect(settings.pick == nil)
        #expect(settings.localServerURL == ProviderSettings.defaultLocalServerURL)
        #expect(settings.localServerKey == nil)
        #expect(settings.models.isEmpty)
        #expect(settings.model(for: .summary, on: .claudeCode) == "sonnet")
    }

    @Test func parsesEveryKey() {
        let settings = ProviderSettings.load(config: [
            "ai_provider": "codex",
            "local_server_url": "http://localhost:1234/v1",
            "local_server_key": "test-key",
            "ai_models": #"{"claude-code":{"summary":"opus"},"local":{"dictation":"qwen3"}}"#,
        ])
        #expect(settings.pick == .codex)
        #expect(settings.localServerURL.absoluteString == "http://localhost:1234/v1")
        #expect(settings.localServerKey == "test-key")
        #expect(settings.model(for: .summary, on: .claudeCode) == "opus")
        #expect(settings.model(for: .dictation, on: .claudeCode) == "haiku")
        #expect(settings.model(for: .dictation, on: .localServer) == "qwen3")
    }

    @Test func badValuesFallBack() {
        let settings = ProviderSettings.load(config: [
            "ai_provider": "nope",
            "local_server_url": "not a url at all",
            "ai_models": "{{{",
        ])
        #expect(settings.pick == nil)
        #expect(settings.localServerURL == ProviderSettings.defaultLocalServerURL)
        #expect(settings.models.isEmpty)
    }

    @Test func urlWithoutSchemeGetsHTTPAndTrailingSlashIsDropped() {
        let settings = ProviderSettings.load(config: ["local_server_url": "localhost:11434/v1/"])
        #expect(settings.localServerURL.absoluteString == "http://localhost:11434/v1")
    }

    @Test func settingModelRoundTripsThroughJSON() throws {
        var settings = ProviderSettings.load(config: [:])
        settings = settings.settingModel("opus", for: .summary, on: .claudeCode)
        settings = settings.settingModel("llama3", for: .dictation, on: .localServer)
        let reloaded = ProviderSettings.load(config: ["ai_models": settings.modelsJSON])
        #expect(reloaded.models == settings.models)
        #expect(reloaded.model(for: .summary, on: .claudeCode) == "opus")
        // Unknown providers/tasks in a stored blob are ignored, not fatal.
        let lenient = ProviderSettings.parseModels(#"{"gemini":{"summary":"x"},"codex":{"poem":"y","summary":"o3"}}"#)
        #expect(lenient == [.codex: [.summary: "o3"]])
    }

    @Test func settingsLoadCarriesProviderSettings() {
        let settings = Settings.load(config: ["ai_provider": "local"])
        #expect(settings.providerSettings.pick == .localServer)
    }
}
