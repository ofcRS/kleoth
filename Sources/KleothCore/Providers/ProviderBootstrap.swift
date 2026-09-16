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
    /// - Parameters:
    ///   - appleClient: the adapter used to actually run a completion, or nil
    ///     when Apple on-device cannot do this task (e.g. macOS < 26, or
    ///     `AIProvider.appleOnDevice` doesn't support `task`).
    ///   - appleAvailability: the DETECTOR's verdict for the snapshot — kept
    ///     separate from `appleClient` so a caller that already computed
    ///     `AppleOnDeviceClient.availability()` (to decide whether to build
    ///     `appleClient` in the first place) can pass its exact reason
    ///     through (e.g. "Apple Intelligence is off …") instead of it being
    ///     collapsed to the generic default whenever `appleClient` is nil —
    ///     `nil` covers more cases (macOS < 26, task unsupported) than "not
    ///     available" alone says why.
    public static func select(
        task: AIProvider.Task,
        pick: AIProvider?,
        settings: Settings,
        credentials: Credentials,
        appleClient: (any ChatCompleting)? = nil,
        appleAvailability: ProviderAvailability = .unavailable(reason: "Needs macOS 26")
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
            apple: { appleAvailability }))
        let snapshot = await detector.snapshot(settings: providerSettings, openRouterKey: credentials.openRouterKey)
        return factory.select(task: task, snapshot: snapshot).map { (factory: factory, selection: $0) }
    }
}
