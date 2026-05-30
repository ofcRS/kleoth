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

    /// Loads settings from disk (config file / defaults).
    public static func load() -> Settings {
        fatalError("unimplemented")
    }
}
