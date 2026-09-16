import Foundation
import KleothCore
import KleothOnDevice

/// The app's merged configuration: `Settings.load()` / `Credentials.resolve()`
/// (environment, `.env`, `~/.config/kleoth/config.json`) with the Keychain's
/// user-edited values overlaid on top. Keychain wins.
///
/// Extracted from `RecordingController` so `DictationController` reads the
/// exact same overlay without depending on the recording controller. Both
/// controllers call these on `init` and on every configuration refresh.
@MainActor
enum AppConfig {
    /// `Settings.load()` + Keychain overlay (+ retired-model migration).
    static func settings() -> KleothCore.Settings {
        mergeSettingsFromKeychain(KleothCore.Settings.load())
    }

    /// `Credentials.resolve()` + Keychain overlay.
    static func credentials() -> Credentials {
        mergeCredentialsFromKeychain(Credentials.resolve())
    }

    static func mergeCredentialsFromKeychain(_ base: Credentials) -> Credentials {
        var merged = base
        if let key = Keychain.get(Keychain.Account.elevenLabsKey), !key.isEmpty {
            merged.elevenLabsKey = key
        }
        if let key = Keychain.get(Keychain.Account.openRouterKey), !key.isEmpty {
            merged.openRouterKey = key
        }
        return merged
    }

    /// Overlays the Keychain values and applies `ModelCatalog.migrating` to
    /// both model slugs. The migration here is IN-MEMORY only — the Keychain
    /// keeps a retired slug until Settings opens and persists the rewrite
    /// (`SettingsView.loadFromController`), so the app works correctly from the
    /// first launch after an update without touching the Keychain on load.
    static func mergeSettingsFromKeychain(_ base: KleothCore.Settings) -> KleothCore.Settings {
        var merged = base
        if let model = Keychain.get(Keychain.Account.defaultModel), !model.isEmpty {
            merged.defaultModel = model
        }
        if let lang = Keychain.get(Keychain.Account.transcriptionLanguage), !lang.isEmpty {
            merged.transcriptionLanguage = lang
        }
        if let auto = Keychain.get(Keychain.Account.autoTranscribe), !auto.isEmpty {
            merged.autoTranscribe = (auto == "true")
        }
        if let path = Keychain.get(Keychain.Account.outputDir), !path.isEmpty {
            merged.outputDir = URL(fileURLWithPath: path, isDirectory: true)
        }
        // Dictation keys: strict "true" opt-in, non-empty model slug.
        if let enabled = Keychain.get(Keychain.Account.dictationEnabled), !enabled.isEmpty {
            merged.dictationEnabled = (enabled == "true")
        }
        if let model = Keychain.get(Keychain.Account.dictationModel), !model.isEmpty {
            merged.dictationModel = model
        }
        if let always = Keychain.get(Keychain.Account.dictationPolishAlways), !always.isEmpty {
            merged.dictationPolishAlways = (always == "true")
        }
        // The microphone pick: a device UID; an EMPTY stored value is the
        // user's explicit "Automatic" and overrides any `config.json` pick.
        if let device = Keychain.get(Keychain.Account.inputDevice) {
            merged.inputDeviceId = device.isEmpty ? nil : device
        }
        // One-time migration for installs that predate the provider pick — the
        // `retiredPolishModels` idiom, except this one DOES persist (a user who
        // already paid for and configured OpenRouter must never be moved off it
        // silently). With no `ai_provider` key the pick reads as Automatic,
        // whose order puts a local server / Claude Code / Codex ahead of
        // OpenRouter, so an existing user would upgrade straight into a
        // different (and much slower) backend for summaries AND dictation.
        // Seeded only when there is a working OpenRouter key AND the install has
        // been used before — `onboarding_completed` for anything since 2026-06,
        // `consent_acknowledged` for the installs that predate that flag. A
        // fresh install stays Automatic. This fires at most once: choosing
        // Automatic writes the `"auto"` sentinel, not an empty string (an empty
        // write DELETES the key, which would look like "never set" and re-seed
        // here on every settings read) — see `updateAIProvider`.
        if Keychain.get(Keychain.Account.aiProvider) == nil,
           let openRouterKey = Keychain.get(Keychain.Account.openRouterKey), !openRouterKey.isEmpty,
           Keychain.get(Keychain.Account.onboardingCompleted) == "true"
            || Keychain.get(Keychain.Account.consentAcknowledged) == "true" {
            Keychain.set(AIProvider.openRouter.rawValue, Keychain.Account.aiProvider)
            merged.providerSettings.pick = .openRouter
        }
        // AI provider: a stored `"auto"` is the user's explicit Automatic and
        // overrides any `config.json` pick (the `input_device` idiom;
        // `AIProvider.parse` maps `"auto"`/unknown → nil).
        if let pick = Keychain.get(Keychain.Account.aiProvider) {
            merged.providerSettings.pick = AIProvider.parse(pick)
        }
        if let url = Keychain.get(Keychain.Account.localServerURL), let normalized = ProviderSettings.normalizeServerURL(url) {
            merged.providerSettings.localServerURL = normalized
        }
        if let key = Keychain.get(Keychain.Account.localServerKey) {
            merged.providerSettings.localServerKey = key.isEmpty ? nil : key
        }
        if let models = Keychain.get(Keychain.Account.aiModels), !models.isEmpty {
            merged.providerSettings.models = ProviderSettings.parseModels(models)
        }
        merged.defaultModel = ModelCatalog.migrating(merged.defaultModel)
        // Chains `ModelCatalog.migrating` and the retired polish defaults
        // (`DictationDefaults.retiredPolishModels`).
        merged.dictationModel = DictationDefaults.migratingPolishModel(merged.dictationModel)
        return merged
    }

    // MARK: - AI providers

    /// One detector for the whole app. Its 10 min cache is what keeps a
    /// dictation off the CLI/server probes on the hot path; every provider
    /// setting change calls `refresh()`, so a stale cache is never what the
    /// user is looking at after they edit something.
    static let detector = ProviderDetector(probes: .standard(
        locator: .standard,
        runner: FoundationProcessRunner(),
        transport: URLSessionTransport(),
        apple: { AppleOnDeviceClient.availability() }), cacheTTL: 600)

    /// The factory for one resolution pass: every backend the user could be
    /// routed to, wired with the app's transport, runner and Apple adapter.
    static func factory(settings: KleothCore.Settings, credentials: Credentials) -> ProviderFactory {
        ProviderFactory(
            settings: settings.effectiveProviderSettings,
            openRouterKey: credentials.openRouterKey,
            transport: URLSessionTransport(),
            runner: FoundationProcessRunner(),
            locator: .standard,
            appleClient: AppleOnDeviceClient.availability().isAvailable ? AppleOnDeviceClient() : nil)
    }

    /// The summarizer for the current settings, or the `ProviderError` that
    /// says why there is none.
    static func makeSummarizer() async throws -> (Summarizer, ProviderFactory.Selection) {
        let settings = settings()
        let credentials = credentials()
        let factory = factory(settings: settings, credentials: credentials)
        let snapshot = await detector.snapshot(settings: settings.effectiveProviderSettings, openRouterKey: credentials.openRouterKey)
        let selection = try factory.select(task: .summary, snapshot: snapshot).get()
        return (try factory.summarizer(for: selection), selection)
    }

    /// The dictation polisher for the current settings, or the `ProviderError`
    /// that says why there is none.
    static func makePolisher() async throws -> (DictationPolisher, ProviderFactory.Selection) {
        let settings = settings()
        let credentials = credentials()
        let factory = factory(settings: settings, credentials: credentials)
        let snapshot = await detector.snapshot(settings: settings.effectiveProviderSettings, openRouterKey: credentials.openRouterKey)
        let selection = try factory.select(task: .dictation, snapshot: snapshot).get()
        return (try factory.polisher(for: selection), selection)
    }

    /// What both tasks resolve to right now — the Settings footer, the popover
    /// and onboarding read this.
    static func providerStatus() async -> ProviderStatus {
        let settings = settings()
        let credentials = credentials()
        let factory = factory(settings: settings, credentials: credentials)
        let snapshot = await detector.snapshot(settings: settings.effectiveProviderSettings, openRouterKey: credentials.openRouterKey)
        return ProviderStatus(
            snapshot: snapshot,
            summary: factory.select(task: .summary, snapshot: snapshot),
            dictation: factory.select(task: .dictation, snapshot: snapshot))
    }
}
