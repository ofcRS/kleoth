import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Turns a `CoverEngine` into a ready `CoverImageGenerating`, the way
/// `ProviderFactory` turns an `AIProvider` into a chat client. The app
/// (`AppConfig`) and the CLI build one; the drawing only ever sees the
/// generator it returns.
///
/// Both transports are injected so tests can tell them apart: OpenRouter goes
/// over the caller's `cloudTransport` (normally
/// `CoverEngineFactory.cloudTransport`), the local server over
/// `localTransport` (normally `CoverEngineFactory.localTransport`).
public struct CoverEngineFactory: Sendable {
    public let settings: Settings
    public let credentials: Credentials
    public let runner: any ProcessRunner
    public let locator: ToolLocator
    public let cloudTransport: HTTPTransport
    public let localTransport: HTTPTransport

    public init(
        settings: Settings, credentials: Credentials, runner: any ProcessRunner, locator: ToolLocator,
        cloudTransport: HTTPTransport, localTransport: HTTPTransport
    ) {
        self.settings = settings
        self.credentials = credentials
        self.runner = runner
        self.locator = locator
        self.cloudTransport = cloudTransport
        self.localTransport = localTransport
    }

    /// The generator for `engine`. Throws the provider layer's own errors, so
    /// an unusable engine reads the same as an unusable summary backend:
    /// OpenRouter with no key is `ProviderError.noProvider`, Codex not found
    /// is `ProviderError.notInstalled`. A local server is not probed here — a
    /// dead one surfaces as `ProviderError.unreachable` on the first draw.
    public func generator(for engine: CoverEngine) throws -> any CoverImageGenerating {
        switch engine {
        case .openRouter:
            guard let key = credentials.openRouterKey, !key.isEmpty else { throw ProviderError.noProvider }
            return ImageGenerationClient(
                baseURL: OpenRouterClient.baseURL, apiKey: key, dialect: .openRouter, transport: cloudTransport)
        case .localServer:
            return ImageGenerationClient(
                baseURL: settings.providerSettings.localServerURL,
                apiKey: settings.providerSettings.localServerKey,
                dialect: .openAICompatible, transport: localTransport)
        case .codex:
            guard let exe = locator.find("codex") else { throw ProviderError.notInstalled(tool: CodexClient.toolName) }
            return CodexImageClient(
                executable: exe, runner: runner, environment: locator.environment(),
                scratchDirectory: Self.codexScratchDirectory, codexHome: Self.codexHome,
                timeout: CoverEngine.codex.budget)
        }
    }

    // MARK: - Defaults

    /// The session a local image server talks over — the
    /// `ProviderFactory.localServerTransport` idiom (ephemeral, no
    /// `waitsForConnectivity`, so nothing listening fails at once instead of
    /// waiting until the app quits), with a longer wait between bytes: the
    /// first picture after a restart includes a cold load of a 5.7 GB image
    /// model, which can keep the socket silent for minutes. The drawing's own
    /// budget (`CoverEngine.localServer.budget`, also 300 s) bounds each
    /// attempt; these limits are the backstop under it. The request timeout
    /// and the budget may race to fire first; both count as transient
    /// (`URLError(.timedOut)` and `KleothTimeoutError`), so either one gets
    /// the same retry, and a final failure reads "Timed out" either way.
    public static let localTransport = URLSessionTransport(session: {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }())

    /// The session OpenRouter's image calls talk over (the app and the CLI
    /// pass it as `cloudTransport`). `URLSessionTransport()`'s default session
    /// waits for connectivity with a 1,200 s request timeout, so with the
    /// Wi-Fi off each attempt hung until the 90 s budget fired — twice, then
    /// "Timed out". Without the wait, offline fails at once with
    /// `URLError(.notConnectedToInternet)`, which is transient: one retry
    /// after 2 s, then "No internet connection". Both limits sit above
    /// `CoverEngine.openRouter.budget`, so that budget is the one that fires
    /// (the `DictationController` transport idiom).
    public static let cloudTransport = URLSessionTransport(session: {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 100
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }())

    /// Codex's home, where `image_gen` saves into `generated_images/`:
    /// `$CODEX_HOME` when set, else `~/.codex`. An empty `CODEX_HOME` counts
    /// as unset — as a path it would name the process's working directory.
    /// Computed on every read, not stored, so no mutable static state exists.
    /// `CodexImageClient` hands the same path to the child as `CODEX_HOME`,
    /// so the two always agree on the folder.
    public static var codexHome: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    /// The folder Codex's read-only sandbox is rooted at (`-C`) while it
    /// draws, so nothing of the user's is in scope. A folder of its own, apart
    /// from the summaries' `kleoth-codex`; `CodexImageClient` creates it.
    public static let codexScratchDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("kleoth-codex-covers", isDirectory: true)
}
