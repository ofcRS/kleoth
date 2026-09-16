import Foundation

/// Finds out what is usable right now: a key, a server answering, a CLI that
/// is installed AND signed in, Apple Intelligence on. Probes are injected so
/// tests never touch the filesystem or the network; results are cached for
/// `cacheTTL` (the dictation path resolves on every run and must not pay a
/// server probe each time).
public actor ProviderDetector {
    public struct Probes: Sendable {
        /// Model ids served at the URL, or the connection error.
        public var localServer: @Sendable (URL) async -> Result<[String], Error>
        public var claudeCode: @Sendable () async -> ProviderAvailability
        public var codex: @Sendable () async -> ProviderAvailability
        /// Supplied by the app (Foundation Models lives there); the core
        /// default reports "Needs macOS 26".
        public var apple: @Sendable () async -> ProviderAvailability

        public init(
            localServer: @escaping @Sendable (URL) async -> Result<[String], Error>,
            claudeCode: @escaping @Sendable () async -> ProviderAvailability,
            codex: @escaping @Sendable () async -> ProviderAvailability,
            apple: @escaping @Sendable () async -> ProviderAvailability = { .unavailable(reason: "Needs macOS 26") }
        ) {
            self.localServer = localServer
            self.claudeCode = claudeCode
            self.codex = codex
            self.apple = apple
        }

        /// The real probes: HTTP for the server, `claude auth status` and
        /// `codex login status` for the CLIs (10 s ceiling each).
        public static func standard(
            locator: ToolLocator,
            runner: any ProcessRunner,
            transport: HTTPTransport,
            apple: @escaping @Sendable () async -> ProviderAvailability = { .unavailable(reason: "Needs macOS 26") }
        ) -> Probes {
            Probes(
                localServer: { url in
                    do { return .success(try await LocalModelList.fetch(baseURL: url, apiKey: nil, transport: transport)) }
                    catch { return .failure(error) }
                },
                claudeCode: {
                    guard let exe = locator.find("claude") else { return .unavailable(reason: "Not installed") }
                    let env = locator.environment()
                    let version = await Self.version(of: exe, runner: runner, environment: env)
                    guard let status = try? await runner.run(executable: exe, arguments: ["auth", "status"], stdin: nil,
                                                             environment: env, timeout: 10),
                          let object = try? JSONSerialization.jsonObject(with: status.stdout) as? [String: Any],
                          object["loggedIn"] as? Bool == true else {
                        return .unavailable(reason: "Not signed in")
                    }
                    return .available(detail: "Claude Code \(version) · signed in")
                },
                codex: {
                    guard let exe = locator.find("codex") else { return .unavailable(reason: "Not installed") }
                    let env = locator.environment()
                    let version = await Self.version(of: exe, runner: runner, environment: env)
                    guard let status = try? await runner.run(executable: exe, arguments: ["login", "status"], stdin: nil,
                                                             environment: env, timeout: 10),
                          status.stdoutText.contains("Logged in") else {
                        return .unavailable(reason: "Not signed in")
                    }
                    return .available(detail: "Codex \(version) · signed in")
                },
                apple: apple)
        }

        /// First token of `<tool> --version` ("2.1.272 (Claude Code)" → "2.1.272";
        /// "codex-cli 0.153.4" → "0.153.4"). Empty when it cannot be read.
        static func version(of executable: URL, runner: any ProcessRunner, environment: [String: String]) async -> String {
            guard let result = try? await runner.run(executable: executable, arguments: ["--version"], stdin: nil,
                                                     environment: environment, timeout: 10) else { return "" }
            let tokens = result.stdoutText.split(whereSeparator: { $0 == " " || $0.isNewline })
            return tokens.first { $0.first?.isNumber == true }.map(String.init) ?? ""
        }
    }

    private struct CacheKey: Equatable {
        let localURL: URL
        let hasOpenRouterKey: Bool
    }

    private let probes: Probes
    private let cacheTTL: TimeInterval
    private var cached: (key: CacheKey, at: Date, snapshot: ProviderSnapshot)?

    public init(probes: Probes, cacheTTL: TimeInterval = 60) {
        self.probes = probes
        self.cacheTTL = cacheTTL
    }

    /// Drops the cache (Settings' Refresh, a settings change, `didBecomeActive`).
    public func refresh() {
        cached = nil
    }

    public func snapshot(settings: ProviderSettings, openRouterKey: String?) async -> ProviderSnapshot {
        let key = CacheKey(localURL: settings.localServerURL, hasOpenRouterKey: !(openRouterKey ?? "").isEmpty)
        if let cached, cached.key == key, Date().timeIntervalSince(cached.at) < cacheTTL {
            return cached.snapshot
        }
        async let local = probes.localServer(settings.localServerURL)
        async let claude = probes.claudeCode()
        async let codex = probes.codex()
        async let apple = probes.apple()

        var snap: ProviderSnapshot = [:]
        snap[.openRouter] = key.hasOpenRouterKey ? .available(detail: "API key set") : .unavailable(reason: "No API key")
        switch await local {
        case let .success(models):
            snap[.localServer] = .available(detail: "\(Self.hostLabel(settings.localServerURL)) · \(models.count) models", models: models)
        case .failure:
            snap[.localServer] = .unavailable(reason: "No server at \(Self.originLabel(settings.localServerURL))")
        }
        snap[.claudeCode] = await claude
        snap[.codex] = await codex
        snap[.appleOnDevice] = await apple
        cached = (key, Date(), snap)
        return snap
    }

    /// `localhost:11434`
    static func hostLabel(_ url: URL) -> String {
        var label = url.host ?? url.absoluteString
        if let port = url.port { label += ":\(port)" }
        return label
    }

    /// `http://localhost:11434`
    static func originLabel(_ url: URL) -> String {
        (url.scheme.map { "\($0)://" } ?? "") + hostLabel(url)
    }
}
