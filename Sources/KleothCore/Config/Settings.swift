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

    public init(
        outputDir: URL,
        defaultModel: String,
        transcriptionLanguage: String? = nil,
        autoTranscribe: Bool = false,
        dictationEnabled: Bool = false,
        dictationModel: String = DictationDefaults.polishModel
    ) {
        self.outputDir = outputDir
        self.defaultModel = defaultModel
        self.transcriptionLanguage = transcriptionLanguage
        self.autoTranscribe = autoTranscribe
        self.dictationEnabled = dictationEnabled
        self.dictationModel = dictationModel
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

        return Settings(
            outputDir: outputDir,
            defaultModel: defaultModel,
            transcriptionLanguage: transcriptionLanguage,
            autoTranscribe: autoTranscribe,
            dictationEnabled: dictationEnabled,
            dictationModel: dictationModel
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
