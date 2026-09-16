import Foundation

/// The CLIs' one-liner: settings + credentials (+ an optional `--provider`
/// override) → a factory and the selection for a task. The app has its own
/// cached detector in `AppConfig`; the tools build a fresh one per run.
public enum ProviderBootstrap {
    /// Resolves the provider/model for `task`, honouring an explicit
    /// `--provider` pick over `settings`. Uses `settings.effectiveProviderSettings`
    /// (not the raw `providerSettings`) so a CLI run resolves OpenRouter's
    /// model the same way the app does — seeded from the legacy
    /// `defaultModel` / `dictationModel` keys when `ai_models` names none.
    public static func select(
        task: AIProvider.Task,
        pick: AIProvider?,
        settings: Settings,
        credentials: Credentials,
        appleClient: (any ChatCompleting)? = nil
    ) async -> Result<(factory: ProviderFactory, selection: ProviderFactory.Selection), ProviderError> {
        var providerSettings = settings.effectiveProviderSettings
        if let pick { providerSettings.pick = pick }
        let runner = FoundationProcessRunner()
        let transport = URLSessionTransport()
        let factory = ProviderFactory(
            settings: providerSettings, openRouterKey: credentials.openRouterKey, transport: transport,
            runner: runner, locator: .standard, appleClient: appleClient)
        let detector = ProviderDetector(probes: .standard(
            locator: .standard, runner: runner, transport: transport,
            apple: { appleClient == nil ? .unavailable(reason: "Needs macOS 26") : .available(detail: "Apple on-device") }))
        let snapshot = await detector.snapshot(settings: providerSettings, openRouterKey: credentials.openRouterKey)
        return factory.select(task: task, snapshot: snapshot).map { (factory: factory, selection: $0) }
    }
}
