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

    public init(
        outputDir: URL,
        defaultModel: String,
        transcriptionLanguage: String? = nil
    ) {
        self.outputDir = outputDir
        self.defaultModel = defaultModel
        self.transcriptionLanguage = transcriptionLanguage
    }

    /// Loads settings, applying defaults:
    /// - `outputDir`: `~/Kleoth` (callers create it lazily).
    /// - `defaultModel`: `google/gemini-3-flash-preview`.
    public static func load() -> Settings {
        let outputDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Kleoth", isDirectory: true)

        let defaultModel = "google/gemini-3-flash-preview"

        let config = loadConfigJSON()

        // Normalize to the struct's contract (nil == auto): an empty value or the
        // literal "auto" both mean automatic detection, so they decode to nil
        // rather than being stored verbatim.
        var transcriptionLanguage: String?
        if let lang = config["transcription_language"],
           !lang.isEmpty, lang.lowercased() != "auto" {
            transcriptionLanguage = lang
        }

        return Settings(
            outputDir: outputDir,
            defaultModel: defaultModel,
            transcriptionLanguage: transcriptionLanguage
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
