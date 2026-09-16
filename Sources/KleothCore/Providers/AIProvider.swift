import Foundation

/// A language-model backend Kleoth can run summaries and dictation polish on.
/// The raw value is the stored id (`ai_provider`, `summary_provider`,
/// `polish_provider`, the `ai_models` keys, `--provider`).
public enum AIProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case openRouter = "openrouter"
    case localServer = "local"
    case claudeCode = "claude-code"
    case codex = "codex"
    case appleOnDevice = "apple"

    /// The two things a provider is asked to do.
    public enum Task: String, Sendable, CaseIterable, Codable {
        case summary, dictation
    }

    /// How Settings lets the user choose a model on this provider.
    public enum ModelChoice: Sendable, Equatable {
        /// OpenRouter's live catalog (`ModelCatalog`).
        case openRouterCatalog
        /// `GET <base>/models` on the local server.
        case serverList
        /// A fixed list of aliases.
        case aliases([String])
        /// Free text; empty means the account default.
        case freeText(placeholder: String)
        /// One model, nothing to pick.
        case fixed
    }

    public var id: String { rawValue }

    /// The order Automatic tries, per task, skipping providers that cannot do
    /// the task or are unavailable.
    public static let autoOrder: [AIProvider] = [.localServer, .claudeCode, .codex, .openRouter, .appleOnDevice]

    /// Claude Code's model aliases (`claude --model`).
    public static let claudeCodeAliases = ["haiku", "sonnet", "opus", "fable"]

    public func supports(_ task: Task) -> Bool {
        switch (self, task) {
        case (.codex, .dictation): return false      // 12 s per call — summaries only
        case (.appleOnDevice, .summary): return false // 4096-token context
        default: return true
        }
    }

    public var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .localServer: return "Local server"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .appleOnDevice: return "Apple on-device"
        }
    }

    /// The model used when the user has not picked one for `task`.
    /// Empty = "the backend's own default" (local server: the first model it
    /// lists; Codex: the account default, no `-m`).
    public func defaultModel(for task: Task) -> String {
        switch (self, task) {
        case (.openRouter, .summary): return ModelCatalog.defaultModel
        case (.openRouter, .dictation): return DictationDefaults.polishModel
        case (.claudeCode, .summary): return "sonnet"
        case (.claudeCode, .dictation): return "haiku"
        case (.appleOnDevice, _): return "apple-on-device"
        case (.localServer, _), (.codex, _): return ""
        }
    }

    public var modelChoice: ModelChoice {
        switch self {
        case .openRouter: return .openRouterCatalog
        case .localServer: return .serverList
        case .claudeCode: return .aliases(Self.claudeCodeAliases)
        case .codex: return .freeText(placeholder: "Account default")
        case .appleOnDevice: return .fixed
        }
    }

    /// A stored / typed id → provider. `nil`, empty, `"auto"` and unknown
    /// strings all mean Automatic.
    public static func parse(_ raw: String?) -> AIProvider? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty, raw != "auto" else { return nil }
        return AIProvider(rawValue: raw)
    }
}
