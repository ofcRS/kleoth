import Foundation

/// The user's provider choices, parsed from the flat string config
/// (`config.json` for the CLI, the Keychain overlay in the app). Pure and
/// value-typed so both can share the parsing and the tests.
public struct ProviderSettings: Sendable, Equatable {
    /// Explicit pick; nil = Automatic.
    public var pick: AIProvider?
    /// API root of the local OpenAI-compatible server.
    public var localServerURL: URL
    /// Optional bearer token for the local server (LM Studio can require one).
    public var localServerKey: String?
    /// Per-provider, per-task model overrides. Absent → `provider.defaultModel(for:)`.
    public var models: [AIProvider: [AIProvider.Task: String]]

    public static let defaultLocalServerURL = URL(string: "http://localhost:11434/v1")!

    public init(
        pick: AIProvider? = nil,
        localServerURL: URL = ProviderSettings.defaultLocalServerURL,
        localServerKey: String? = nil,
        models: [AIProvider: [AIProvider.Task: String]] = [:]
    ) {
        self.pick = pick
        self.localServerURL = localServerURL
        self.localServerKey = localServerKey
        self.models = models
    }

    // MARK: - Parsing

    public static func load(config: [String: String]) -> ProviderSettings {
        var settings = ProviderSettings()
        settings.pick = AIProvider.parse(config["ai_provider"])
        settings.localServerURL = normalizeServerURL(config["local_server_url"]) ?? defaultLocalServerURL
        if let key = config["local_server_key"], !key.isEmpty {
            settings.localServerKey = key
        }
        settings.models = parseModels(config["ai_models"])
        return settings
    }

    /// `"localhost:11434/v1/"` → `http://localhost:11434/v1`. nil for empty
    /// or unparseable input (the caller falls back to the default).
    public static func normalizeServerURL(_ raw: String?) -> URL? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let host = url.host, !host.isEmpty, !host.contains(" ") else { return nil }
        return url
    }

    /// Decodes the `ai_models` blob leniently: unknown providers and tasks are
    /// dropped, anything undecodable yields an empty map.
    public static func parseModels(_ json: String?) -> [AIProvider: [AIProvider.Task: String]] {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [AIProvider: [AIProvider.Task: String]] = [:]
        for (providerKey, value) in object {
            guard let provider = AIProvider(rawValue: providerKey),
                  let byTask = value as? [String: Any] else { continue }
            var models: [AIProvider.Task: String] = [:]
            for (taskKey, model) in byTask {
                if let task = AIProvider.Task(rawValue: taskKey), let model = model as? String, !model.isEmpty {
                    models[task] = model
                }
            }
            if !models.isEmpty { result[provider] = models }
        }
        return result
    }

    // MARK: - Models

    /// The model to use for `task` on `provider`: the stored override, else
    /// the provider's default.
    public func model(for task: AIProvider.Task, on provider: AIProvider) -> String {
        models[provider]?[task] ?? provider.defaultModel(for: task)
    }

    /// A copy with one override set (empty `model` removes the override).
    public func settingModel(_ model: String, for task: AIProvider.Task, on provider: AIProvider) -> ProviderSettings {
        var copy = self
        var byTask = copy.models[provider] ?? [:]
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { byTask[task] = nil } else { byTask[task] = trimmed }
        copy.models[provider] = byTask.isEmpty ? nil : byTask
        return copy
    }

    /// The `ai_models` blob to persist. Keys sorted so the value is stable.
    public var modelsJSON: String {
        var object: [String: [String: String]] = [:]
        for (provider, byTask) in models {
            object[provider.rawValue] = Dictionary(uniqueKeysWithValues: byTask.map { ($0.key.rawValue, $0.value) })
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
