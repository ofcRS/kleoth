import Testing
@testable import KleothCore

@Suite struct ProviderStatusTests {
    @Test func footerNamesBothTasks() {
        let status = ProviderStatus(
            snapshot: [:],
            summary: .success(.init(provider: .claudeCode, model: "sonnet", fellThroughFrom: .appleOnDevice)),
            dictation: .success(.init(provider: .appleOnDevice, model: "apple-on-device", fellThroughFrom: nil)))
        #expect(status.footerText == "Summaries via Claude Code (Apple on-device cannot summarize) · Dictation via Apple on-device")
    }

    @Test func footerShowsErrors() {
        let status = ProviderStatus(snapshot: [:], summary: .failure(.noProvider), dictation: .failure(.notSignedIn(tool: "Claude Code")))
        #expect(status.footerText == "Summaries: No AI provider available — open Settings → Accounts. · Dictation: Claude Code is not signed in. Open a terminal, run `claude`, and sign in.")
    }

    @Test func detectedNamesListAvailableProvidersInAutoOrder() {
        let status = ProviderStatus(
            snapshot: [.openRouter: .available(detail: "k"), .claudeCode: .available(detail: "c"), .codex: .unavailable(reason: "x")],
            summary: .failure(.noProvider), dictation: .failure(.noProvider))
        #expect(status.detectedNames == ["Claude Code", "OpenRouter"])
    }
}
