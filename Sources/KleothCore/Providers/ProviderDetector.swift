import Foundation

/// Finds out what is usable right now: a key, a server answering, a CLI that
/// is installed AND signed in, Apple Intelligence on. Probes are injected so
/// tests never touch the filesystem or the network; results are cached for
/// `cacheTTL` (the dictation path resolves on every run and must not pay a
/// server probe each time).
public actor ProviderDetector {
    public struct Probes: Sendable {
        /// Model ids served at the URL with the given bearer key (LM Studio can
        /// require one; Ollama needs none), or the connection error.
        public var localServer: @Sendable (URL, String?) async -> Result<[String], Error>
        public var claudeCode: @Sendable () async -> ProviderAvailability
        public var codex: @Sendable () async -> ProviderAvailability
        /// Supplied by the app (Foundation Models lives there); the core
        /// default reports "Needs macOS 26".
        public var apple: @Sendable () async -> ProviderAvailability

        public init(
            localServer: @escaping @Sendable (URL, String?) async -> Result<[String], Error>,
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
        ///
        /// `transport` is accepted for API stability (existing callers pass the
        /// app's shared `URLSessionTransport`) but the local-server probe below
        /// does NOT use it: that shared session is tuned for long Scribe
        /// uploads (`URLSessionTransport.defaultSession` sets
        /// `waitsForConnectivity = true`), which silently ignores a request's
        /// own short `timeoutInterval` and can hang for
        /// `timeoutIntervalForResource` (days, on the default config) when a
        /// connection is refused or DNS fails — exactly what "is anything
        /// listening on the local server URL?" hits whenever nothing is. The
        /// local probe instead builds its own short-lived, fast-failing
        /// session, scoped to this one check.
        public static func standard(
            locator: ToolLocator,
            runner: any ProcessRunner,
            transport: HTTPTransport,
            apple: @escaping @Sendable () async -> ProviderAvailability = { .unavailable(reason: "Needs macOS 26") }
        ) -> Probes {
            let localProbeTransport = URLSessionTransport(session: {
                let config = URLSessionConfiguration.ephemeral
                config.waitsForConnectivity = false
                config.timeoutIntervalForRequest = 2
                config.timeoutIntervalForResource = 3
                return URLSession(configuration: config)
            }())
            return Probes(
                localServer: { url, apiKey in
                    do { return .success(try await LocalModelList.fetch(baseURL: url, apiKey: apiKey, transport: localProbeTransport)) }
                    catch { return .failure(error) }
                },
                claudeCode: {
                    guard let exe = locator.find("claude") else { return .unavailable(reason: "Not installed") }
                    let env = locator.environment()
                    let version = await Self.version(of: exe, runner: runner, environment: env)
                    let status: ProcessResult
                    do {
                        status = try await runner.run(executable: exe, arguments: ["auth", "status"], stdin: nil,
                                                       environment: env, timeout: 10)
                    } catch {
                        // A hung/killed CLI answered nothing — do not tell the
                        // user to sign in, they may already be.
                        return .unavailable(reason: "Did not answer")
                    }
                    guard let object = try? JSONSerialization.jsonObject(with: status.stdout) as? [String: Any],
                          object["loggedIn"] as? Bool == true else {
                        return .unavailable(reason: "Not signed in")
                    }
                    return .available(detail: "Claude Code \(version) · signed in")
                },
                codex: {
                    guard let exe = locator.find("codex") else { return .unavailable(reason: "Not installed") }
                    let env = locator.environment()
                    let version = await Self.version(of: exe, runner: runner, environment: env)
                    let status: ProcessResult
                    do {
                        status = try await runner.run(executable: exe, arguments: ["login", "status"], stdin: nil,
                                                       environment: env, timeout: 10)
                    } catch {
                        return .unavailable(reason: "Did not answer")
                    }
                    // `codex login status` prints "Logged in using ChatGPT" to
                    // STDERR, not stdout (verified live, codex-cli 0.153.4/
                    // 0.154.0) — checking stdout alone always read "Not signed
                    // in" even for a signed-in account.
                    guard status.stdoutText.contains("Logged in") || status.stderrText.contains("Logged in") else {
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
        /// The actual key, not just its presence: it never leaves this
        /// actor-private struct, and comparing the value (not a boolean) is
        /// what makes editing it in Settings invalidate the cache.
        let localServerKey: String?
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
        let key = CacheKey(
            localURL: settings.localServerURL,
            localServerKey: settings.localServerKey,
            hasOpenRouterKey: !(openRouterKey ?? "").isEmpty)
        if let cached, cached.key == key, Date().timeIntervalSince(cached.at) < cacheTTL {
            return cached.snapshot
        }
        async let local = probes.localServer(settings.localServerURL, settings.localServerKey)
        async let claude = probes.claudeCode()
        async let codex = probes.codex()
        async let apple = probes.apple()

        var snap: ProviderSnapshot = [:]
        snap[.openRouter] = key.hasOpenRouterKey ? .available(detail: "API key set") : .unavailable(reason: "No API key")
        switch await local {
        case let .success(models):
            let count = "\(models.count) model\(models.count == 1 ? "" : "s")"
            snap[.localServer] = .available(detail: "\(Self.hostLabel(settings.localServerURL)) · \(count)", models: models)
        case .failure:
            snap[.localServer] = .unavailable(reason: "No server at \(Self.originLabel(settings.localServerURL))")
        }
        snap[.claudeCode] = await claude
        snap[.codex] = await codex
        snap[.appleOnDevice] = await apple
        // Under cancellation the probes are full of FALSE negatives: the
        // process runner terminates the child and throws, the transport throws
        // `URLError(.cancelled)`, and each probe turns that into "Did not
        // answer" / "No server at …". Caching that would pin a wrong verdict
        // for the whole TTL (and route the next dictation or summary wrongly),
        // so the caller gets the snapshot but the cache does not.
        guard !Task.isCancelled else { return snap }
        cached = (key, Date(), snap)
        return snap
    }

    /// `localhost:11434`. Public so the app's covers status line names the
    /// server exactly as the provider rows do.
    public static func hostLabel(_ url: URL) -> String {
        var label = url.host ?? url.absoluteString
        if let port = url.port { label += ":\(port)" }
        return label
    }

    /// `http://localhost:11434`
    static func originLabel(_ url: URL) -> String {
        (url.scheme.map { "\($0)://" } ?? "") + hostLabel(url)
    }
}
