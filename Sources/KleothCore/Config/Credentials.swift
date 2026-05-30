import Foundation

/// API credentials resolved from the environment / project configuration.
public struct Credentials: Sendable {
    public var elevenLabsKey: String?
    public var openRouterKey: String?

    public init(elevenLabsKey: String? = nil, openRouterKey: String? = nil) {
        self.elevenLabsKey = elevenLabsKey
        self.openRouterKey = openRouterKey
    }

    /// Resolves credentials from `.env` / environment, relative to `projectDir`.
    public static func resolve(
        projectDir: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> Credentials {
        fatalError("unimplemented")
    }
}
