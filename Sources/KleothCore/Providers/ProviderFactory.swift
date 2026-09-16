import Foundation

/// Turns settings + a detector snapshot into a ready `Summarizer` /
/// `DictationPolisher`. The app (`AppConfig`) and the CLIs are its only callers.
public struct ProviderFactory: Sendable {
    /// The provider and model one call will run on.
    public struct Selection: Sendable, Equatable {
        public let provider: AIProvider
        public let model: String
        /// An explicit pick that could not do this task (Settings footer copy).
        public let fellThroughFrom: AIProvider?

        public init(provider: AIProvider, model: String, fellThroughFrom: AIProvider?) {
            self.provider = provider
            self.model = model
            self.fellThroughFrom = fellThroughFrom
        }
    }

    public var settings: ProviderSettings
    public var openRouterKey: String?
    public var transport: HTTPTransport
    public var runner: any ProcessRunner
    public var locator: ToolLocator
    /// The Foundation Models adapter, supplied by the app; nil elsewhere.
    public var appleClient: (any ChatCompleting)?

    public init(
        settings: ProviderSettings, openRouterKey: String?, transport: HTTPTransport,
        runner: any ProcessRunner, locator: ToolLocator, appleClient: (any ChatCompleting)?
    ) {
        self.settings = settings
        self.openRouterKey = openRouterKey
        self.transport = transport
        self.runner = runner
        self.locator = locator
        self.appleClient = appleClient
    }

    // MARK: - Selection

    public func select(task: AIProvider.Task, snapshot: ProviderSnapshot) -> Result<Selection, ProviderError> {
        switch ProviderResolver.resolve(task: task, pick: settings.pick, snapshot: snapshot) {
        case .none:
            return .failure(.noProvider)
        case let .unavailable(provider, reason):
            return .failure(ProviderError.from(provider: provider, reason: reason, url: settings.localServerURL))
        case let .provider(provider, fellThroughFrom):
            var model = settings.model(for: task, on: provider)
            if model.isEmpty, provider == .localServer {
                if case let .available(_, models)? = snapshot[.localServer] { model = models.first ?? "" }
                if model.isEmpty {
                    return .failure(.backend("The local server lists no models — run `ollama pull <model>` first."))
                }
            }
            return .success(Selection(provider: provider, model: model, fellThroughFrom: fellThroughFrom))
        }
    }

    // MARK: - Clients

    /// The session the local server talks over. The app's default transport is
    /// tuned for ElevenLabs uploads — `waitsForConnectivity = true` and a
    /// 20-minute request timeout — which is exactly wrong for `localhost`: with
    /// no server listening the call would sit there until the app quits instead
    /// of failing in a second. A long summary on a big local model can still
    /// legitimately run for minutes, hence 120 s between bytes and a 10-minute
    /// ceiling for the whole request. OpenRouter keeps the injected transport.
    public static let localServerTransport = URLSessionTransport(session: {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }())

    public func client(for provider: AIProvider) throws -> any ChatCompleting {
        switch provider {
        case .openRouter:
            guard let key = openRouterKey, !key.isEmpty else { throw ProviderError.noProvider }
            return OpenRouterClient(apiKey: key, transport: transport)
        case .localServer:
            // Deliberately NOT the injected transport — see `localServerTransport`.
            return OpenAICompatibleClient(
                baseURL: settings.localServerURL, apiKey: settings.localServerKey,
                transport: Self.localServerTransport)
        case .claudeCode:
            guard let exe = locator.find("claude") else { throw ProviderError.notInstalled(tool: ClaudeCodeClient.toolName) }
            return ClaudeCodeClient(executable: exe, runner: runner, environment: locator.environment())
        case .codex:
            guard let exe = locator.find("codex") else { throw ProviderError.notInstalled(tool: CodexClient.toolName) }
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("kleoth-codex", isDirectory: true)
            return CodexClient(executable: exe, runner: runner, environment: locator.environment(), scratchDirectory: scratch)
        case .appleOnDevice:
            guard let appleClient else { throw ProviderError.unsupported("Apple on-device is not available.") }
            return appleClient
        }
    }

    public func summarizer(for selection: Selection) throws -> Summarizer {
        Summarizer(client: try client(for: selection.provider), model: selection.model)
    }

    /// The OpenRouter fallback model (a second slug tried on an HTTP error)
    /// makes no sense on any other backend, so it is nil there.
    public func polisher(for selection: Selection, timeout: TimeInterval = DictationDefaults.polishTimeout) throws -> DictationPolisher {
        DictationPolisher(
            client: try client(for: selection.provider),
            model: selection.model,
            timeout: timeout,
            fallbackModel: selection.provider == .openRouter ? DictationDefaults.fallbackPolishModel : nil)
    }
}

public extension ProviderError {
    /// The detector's reason string for an explicitly picked, unusable
    /// provider → the typed error with the right copy.
    static func from(provider: AIProvider, reason: String, url: URL) -> ProviderError {
        switch provider {
        case .localServer:
            return .unreachable(url: url)
        case .openRouter:
            return .noProvider
        case .claudeCode, .codex:
            let tool = provider == .claudeCode ? ClaudeCodeClient.toolName : CodexClient.toolName
            if reason == "Not installed" { return .notInstalled(tool: tool) }
            if reason == "Not signed in" { return .notSignedIn(tool: tool) }
            return .backend(reason)
        case .appleOnDevice:
            return .unsupported(reason)
        }
    }
}
