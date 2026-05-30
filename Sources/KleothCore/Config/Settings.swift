import Foundation

/// User-configurable application settings.
public struct Settings: Sendable {
    public var outputDir: URL
    public var defaultModel: String
    public var slackWebhook: String?

    public init(outputDir: URL, defaultModel: String, slackWebhook: String? = nil) {
        self.outputDir = outputDir
        self.defaultModel = defaultModel
        self.slackWebhook = slackWebhook
    }

    /// Loads settings, applying defaults:
    /// - `outputDir`: `~/Kleoth` (callers create it lazily).
    /// - `defaultModel`: `anthropic/claude-haiku-4.5`.
    /// - `slackWebhook`: `~/.config/kleoth/config.json` (`slack_webhook`), or
    ///   the `SLACK_WEBHOOK` environment variable, if present.
    public static func load() -> Settings {
        let outputDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Kleoth", isDirectory: true)

        let defaultModel = "anthropic/claude-haiku-4.5"

        var slackWebhook: String?
        let config = loadConfigJSON()
        if let webhook = config["slack_webhook"], !webhook.isEmpty {
            slackWebhook = webhook
        }
        if slackWebhook == nil {
            if let envWebhook = ProcessInfo.processInfo.environment["SLACK_WEBHOOK"],
               !envWebhook.isEmpty {
                slackWebhook = envWebhook
            }
        }

        return Settings(
            outputDir: outputDir,
            defaultModel: defaultModel,
            slackWebhook: slackWebhook
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
