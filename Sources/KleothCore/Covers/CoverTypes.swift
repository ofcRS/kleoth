import Foundation

/// The look of a meeting cover. The raw value is the stored id (`cover_style`,
/// `cover.json`'s `style`, the scene step's `style` field, `--style`).
public enum CoverStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case animation, illustration, sketch, clay

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .animation: return "Animation"
        case .illustration: return "Illustration"
        case .sketch: return "Sketch"
        case .clay: return "Clay"
        }
    }

    /// The sentence after "Style:" in the image prompt (design doc §3.4, as
    /// settled by the look test on 2026-09-25: Sketch's washes now fill the
    /// square, because "on warm off-white paper" drew a paper margin in 3 of 4
    /// sketches). The style lives in the prompt, not in the scene: the scene
    /// step is told to describe only what is visible, so one scene can be
    /// redrawn in any style.
    public var promptSentence: String {
        switch self {
        case .animation:
            return "soft 3D animated-film look, rounded plush-toy characters, warm pastel colours, soft even light."
        case .illustration:
            return "flat 2D storybook illustration, simple rounded shapes, soft pastel palette, subtle paper grain, clean outlines."
        case .sketch:
            return "friendly hand-drawn pencil sketch with light watercolour washes that fill the square, warm off-white paper tone."
        case .clay:
            return "handmade clay-and-felt miniature diorama, stop-motion look, tactile textures, soft studio light."
        }
    }
}

/// Which style a cover job asks for. `CoverDrawing.Request.fixedStyle` is a
/// plain optional, where nil means "the scene step picks by mood" (§3.3). That
/// can't also mean "whatever Settings says", and New Cover ▸ needs both. Its
/// Automatic Style is an explicit pick, and §3.3 says "a style fixed in
/// Settings or chosen from New Cover ▸ wins", so it beats a fixed Settings
/// style. Draw Cover, Try Again and the automatic hook follow Settings (§3.5).
/// It lives in core, beside `CoverStyle`, so the mapping is tested.
public enum CoverStyleChoice: Sendable, Equatable {
    /// The Style setting at the time the job runs (nil there = by mood).
    case settings
    /// The scene step picks by mood, whatever Settings says.
    case automatic
    /// This style, whatever Settings says.
    case fixed(CoverStyle)

    /// `CoverDrawing.Request.fixedStyle` for this choice, given the Style
    /// setting (nil = Automatic).
    public func fixedStyle(settingsStyle: CoverStyle?) -> CoverStyle? {
        switch self {
        case .settings: return settingsStyle
        case .automatic: return nil
        case .fixed(let style): return style
        }
    }
}

/// What draws the picture. The raw values are `AIProvider`'s, so a cover's
/// `engine` in `cover.json` reads the same as a summary's `summary_provider`.
public enum CoverEngine: String, Codable, CaseIterable, Sendable, Identifiable {
    case localServer = "local"
    case codex = "codex"
    case openRouter = "openrouter"

    public var id: String { rawValue }

    /// `cover_engine`'s value for Off. Written explicitly, never as an empty
    /// string: an empty Keychain write deletes the key.
    public static let offValue = "off"

    public var displayName: String {
        switch self {
        case .localServer: return "Local server"
        case .codex: return "Codex"
        case .openRouter: return "OpenRouter"
        }
    }

    /// The image model used when `cover_models` names none. Empty for Codex:
    /// it draws with its own built-in image tool and takes no model.
    public var defaultModel: String {
        switch self {
        case .localServer: return "x/flux2-klein"
        case .codex: return ""
        case .openRouter: return "google/gemini-3.1-flash-lite-image"
        }
    }

    /// Seconds one image attempt may take. The local server's allows for a
    /// cold load of a 5.7 GB model; Codex spends about a minute per picture.
    public var budget: TimeInterval {
        switch self {
        case .localServer: return 300
        case .codex: return 240
        case .openRouter: return 90
        }
    }

    /// Extra attempts after a transient failure (timeout, network, 408/429/5xx).
    /// The HTTP engines get one; Codex runs a single attempt (design doc §3.4).
    public var retries: Int {
        switch self {
        case .localServer, .openRouter: return 1
        case .codex: return 0
        }
    }

    /// Whether Settings shows an image-model field for this engine.
    public var takesModel: Bool { self != .codex }
}

/// The user's cover choices, parsed from the flat string config (`config.json`
/// for the CLI, the Keychain overlay in the app), as `ProviderSettings` is.
public struct CoverSettings: Sendable, Equatable {
    /// `cover_engine`; nil = Off, the default — every engine spends money,
    /// plan quota or GPU memory, so picking one is the opt-in.
    public var engine: CoverEngine?
    /// `cover_automatic`: draw right after a summary is saved. On unless the
    /// stored value is exactly `"false"`.
    public var automatic: Bool
    /// `cover_style`; nil = Automatic (the scene step picks by mood).
    public var style: CoverStyle?
    /// `cover_models`: per-engine image-model overrides. Absent → `engine.defaultModel`.
    public var models: [CoverEngine: String]

    public init(
        engine: CoverEngine? = nil,
        automatic: Bool = true,
        style: CoverStyle? = nil,
        models: [CoverEngine: String] = [:]
    ) {
        self.engine = engine
        self.automatic = automatic
        self.style = style
        self.models = models
    }

    // MARK: - Parsing

    /// Garbage never fails a load: an unknown engine reads as Off, an unknown
    /// style as Automatic, an undecodable `cover_models` as no overrides.
    public static func load(config: [String: String]) -> CoverSettings {
        var settings = CoverSettings()
        if let raw = config["cover_engine"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            settings.engine = CoverEngine(rawValue: raw)          // "off", "", unknown → nil
        }
        settings.automatic = config["cover_automatic"] != "false"   // anything but "false" is on
        if let raw = config["cover_style"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            settings.style = CoverStyle(rawValue: raw)            // "auto", unknown → nil
        }
        settings.models = parseModels(config["cover_models"])
        return settings
    }

    /// Decodes the `cover_models` blob leniently: unknown engines, engines that
    /// take no model (Codex — the key holds `local` and `openrouter` only, §4.5)
    /// and empty values are dropped; anything undecodable yields an empty map.
    public static func parseModels(_ json: String?) -> [CoverEngine: String] {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [CoverEngine: String] = [:]
        for (engineKey, value) in object {
            if let engine = CoverEngine(rawValue: engineKey), engine.takesModel,
               let model = value as? String, !model.isEmpty {
                result[engine] = model
            }
        }
        return result
    }

    // MARK: - Models

    /// The image model to ask `engine` for: the stored override, else the
    /// engine's default.
    public func model(for engine: CoverEngine) -> String {
        if let stored = models[engine], !stored.isEmpty { return stored }
        return engine.defaultModel
    }

    /// A copy with one override set; the model is trimmed, and an empty one —
    /// or the engine's own default, retyped from the field's placeholder —
    /// removes the override. A pinned copy of the default would otherwise
    /// shadow a later change of `defaultModel`, and the user never picked it.
    public func settingModel(_ model: String, for engine: CoverEngine) -> CoverSettings {
        var copy = self
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.models[engine] = trimmed.isEmpty || trimmed == engine.defaultModel ? nil : trimmed
        return copy
    }

    // MARK: - Storage

    /// The `cover_models` blob to persist. Keys sorted so the value is stable;
    /// slashes deliberately left unescaped (`.withoutEscapingSlashes`), unlike
    /// `ProviderSettings.modelsJSON`, because every model id has one
    /// (`x/flux2-klein`) and users hand-edit this value in `config.json`. Both
    /// forms decode the same.
    public var modelsJSON: String {
        let object = Dictionary(uniqueKeysWithValues: models.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The `cover_engine` value to persist: never empty (see `CoverEngine.offValue`).
    public var engineStorageValue: String { engine?.rawValue ?? CoverEngine.offValue }

    /// The `cover_style` value to persist; Automatic is written as `"auto"`.
    public var styleStorageValue: String { style?.rawValue ?? "auto" }
}
