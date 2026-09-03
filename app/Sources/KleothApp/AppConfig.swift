import Foundation
import KleothCore

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
        merged.defaultModel = ModelCatalog.migrating(merged.defaultModel)
        merged.dictationModel = ModelCatalog.migrating(merged.dictationModel)
        return merged
    }
}
