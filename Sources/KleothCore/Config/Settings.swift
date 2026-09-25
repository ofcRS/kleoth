import Foundation

/// User-configurable application settings.
public struct Settings: Sendable {
    public var outputDir: URL
    public var defaultModel: String
    /// Preferred on-device transcription language as a Whisper code (e.g. `"ru"`,
    /// `"en"`). `nil` or empty means automatic detection. Pinning a language is
    /// the bulletproof path when auto-detection would otherwise misfire (e.g.
    /// short or noisy openings being read as English).
    public var transcriptionLanguage: String?
    /// Whether a finished recording is transcribed automatically. Off by
    /// default: recordings wait in the list as "Untranscribed" until the user
    /// picks an engine (free on-device or paid cloud).
    public var autoTranscribe: Bool
    /// Whether the global fn+shift dictation hotkey is active. Strict opt-in
    /// (`"true"` only), off by default — including on existing installs.
    public var dictationEnabled: Bool
    /// OpenRouter model used for the one dictation "polish" call. Defaults to
    /// `DictationDefaults.polishModel`.
    public var dictationModel: String
    /// Run the polish call on EVERY dictation. Off by default: short
    /// utterances and messages into chat apps paste Scribe's transcript
    /// directly (`PolishGate`). Strict opt-in (`"true"` only).
    public var dictationPolishAlways: Bool
    /// Read the focused field at release — its selection and the text around
    /// the caret — and send it with the words to a provider that takes it
    /// (`AIProvider.supportsDictationContext`), so the result fits and a
    /// selection is merged (dictation-context design §3.1). On by default: the
    /// text goes only to the provider that already gets the words, and
    /// password fields are never read. The reverse of the strict opt-ins: only
    /// the literal `"false"` turns it off.
    public var dictationContext: Bool
    /// The microphone every capture opens — a CoreAudio device UID — or nil
    /// for "Automatic" (the system input). Picked from the pill's menu or
    /// Settings; honoured by meeting recordings, dictation and screen
    /// recordings alike. A pick that is not connected falls back to the
    /// system input at capture time (the capture layer decides, not this).
    public var inputDeviceId: String?
    /// Which language-model backend runs summaries and dictation polish (design doc 2026-09-15).
    public var providerSettings: ProviderSettings

    public init(
        outputDir: URL,
        defaultModel: String,
        transcriptionLanguage: String? = nil,
        autoTranscribe: Bool = false,
        dictationEnabled: Bool = false,
        dictationModel: String = DictationDefaults.polishModel,
        dictationPolishAlways: Bool = false,
        dictationContext: Bool = true,
        inputDeviceId: String? = nil,
        providerSettings: ProviderSettings = ProviderSettings()
    ) {
        self.outputDir = outputDir
        self.defaultModel = defaultModel
        self.transcriptionLanguage = transcriptionLanguage
        self.autoTranscribe = autoTranscribe
        self.dictationEnabled = dictationEnabled
        self.dictationModel = dictationModel
        self.dictationPolishAlways = dictationPolishAlways
        self.dictationContext = dictationContext
        self.inputDeviceId = inputDeviceId
        self.providerSettings = providerSettings
    }

    /// `providerSettings` with OpenRouter's two models filled from the
    /// legacy `defaultModel` / `dictationModel` settings when no `ai_models`
    /// override names them — those keys stay the OpenRouter picks.
    ///
    /// Without this, an existing user's `default_model` / `dictation_model`
    /// would be silently ignored the moment the provider layer took over:
    /// `ProviderFactory` resolves OpenRouter's model through
    /// `AIProvider.defaultModel(for:)`, which knows only the shipped constants.
    /// The seeded values are NOT written back to `ai_models` — the legacy keys
    /// remain the single source of truth for OpenRouter.
    public var effectiveProviderSettings: ProviderSettings {
        var effective = providerSettings
        if effective.models[.openRouter]?[.summary] == nil {
            effective = effective.settingModel(defaultModel, for: .summary, on: .openRouter)
        }
        if effective.models[.openRouter]?[.dictation] == nil {
            effective = effective.settingModel(dictationModel, for: .dictation, on: .openRouter)
        }
        return effective
    }

    /// Loads settings, applying defaults:
    /// - `outputDir`: `~/Kleoth` (callers create it lazily).
    /// - `defaultModel`: `ModelCatalog.defaultModel`.
    public static func load() -> Settings {
        load(config: loadConfigJSON())
    }

    /// `load()` with the config dictionary injected, so parsing is testable
    /// without touching the real `~/.config/kleoth/config.json`.
    static func load(config: [String: String]) -> Settings {
        let outputDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Kleoth", isDirectory: true)

        let defaultModel = ModelCatalog.defaultModel

        // Normalize to the struct's contract (nil == auto): an empty value or the
        // literal "auto" both mean automatic detection, so they decode to nil
        // rather than being stored verbatim.
        var transcriptionLanguage: String?
        if let lang = config["transcription_language"],
           !lang.isEmpty, lang.lowercased() != "auto" {
            transcriptionLanguage = lang
        }

        // Strict opt-in: only the literal "true" enables it; absent or any
        // other value (malformed "1"/"yes") stays off.
        let autoTranscribe = (config["auto_transcribe"] == "true")

        // Same strict opt-in for the dictation hotkey.
        let dictationEnabled = (config["dictation_enabled"] == "true")

        // Polish model: a non-empty configured slug wins, otherwise the
        // dictation default. (Retired slugs are migrated by the app's Keychain
        // overlay, not here.)
        var dictationModel = DictationDefaults.polishModel
        if let configured = config["dictation_model"], !configured.isEmpty {
            dictationModel = configured
        }

        // Same strict opt-in for "polish every dictation".
        let dictationPolishAlways = (config["dictation_polish_always"] == "true")

        // The reverse for the field context: on by default, so only the
        // literal "false" turns it off; absent or any other value keeps it on.
        let dictationContext = (config["dictation_context"] != "false")

        // The microphone pick: empty or "auto" both mean the system input,
        // the `transcription_language` normalization.
        var inputDeviceId: String?
        if let device = config["input_device"], !device.isEmpty, device.lowercased() != "auto" {
            inputDeviceId = device
        }

        let providerSettings = ProviderSettings.load(config: config)

        return Settings(
            outputDir: outputDir,
            defaultModel: defaultModel,
            transcriptionLanguage: transcriptionLanguage,
            autoTranscribe: autoTranscribe,
            dictationEnabled: dictationEnabled,
            dictationModel: dictationModel,
            dictationPolishAlways: dictationPolishAlways,
            dictationContext: dictationContext,
            inputDeviceId: inputDeviceId,
            providerSettings: providerSettings
        )
    }

    /// Loads `~/.config/kleoth/config.json` as a flat `[String: String]` of its
    /// string-valued entries; non-string values are ignored.
    static func loadConfigJSON() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("kleoth", isDirectory: true)
            .appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any]
        else {
            return [:]
        }
        var result: [String: String] = [:]
        for (key, value) in dict {
            if let string = value as? String {
                result[key] = string
            }
        }
        return result
    }
}
