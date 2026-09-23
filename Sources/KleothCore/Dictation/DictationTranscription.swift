import Foundation

/// How a dictation asks an engine for its transcript: a wall-clock budget per
/// attempt that grows with the clip, and one more try after a transient
/// failure (dictation-retry design §3.1).
///
/// Every Scribe call a dictation makes goes through ``run(_:fileURL:options:policy:onAttemptFailed:)``
/// — the first run, the pill's Retry, a History run — so they all wait and
/// retry the same way. Pure policy: no UI, no files; the controller decides
/// what a final failure means (the audio is kept, the pill offers Retry).
public enum DictationTranscription {
    /// Attempts, per-attempt budget and the pause between attempts.
    public struct Policy: Sendable, Equatable {
        public var attempts: Int
        /// nil = no wall-clock bound (the on-device engine's first model load
        /// after a new build takes minutes and must not be cut off).
        public var budget: TimeInterval?
        public var retryDelay: TimeInterval

        public init(attempts: Int, budget: TimeInterval?, retryDelay: TimeInterval) {
            self.attempts = attempts
            self.budget = budget
            self.retryDelay = retryDelay
        }

        /// ElevenLabs Scribe on a clip `audioSeconds` long.
        public static func scribe(audioSeconds: Double) -> Policy {
            Policy(
                attempts: DictationDefaults.scribeAttempts,
                budget: DictationDefaults.scribeBudget(forAudioSeconds: audioSeconds),
                retryDelay: DictationDefaults.scribeRetryDelay
            )
        }

        /// WhisperKit on this Mac: one attempt, however long it takes.
        public static let onDevice = Policy(attempts: 1, budget: nil, retryDelay: 0)
    }

    /// A transcript, and what it took to get it.
    public struct Result: Sendable {
        public let response: ScribeResponse
        /// Wall clock of the attempt that produced the transcript.
        public let seconds: TimeInterval
        public let attempts: Int
    }

    /// Every attempt failed. A cancellation is never wrapped in this: whatever
    /// else ``run(_:fileURL:options:policy:onAttemptFailed:)`` throws means the
    /// run was cancelled.
    public struct Failure: Error, Sendable, CustomStringConvertible {
        public let underlying: any Error
        public let attempts: Int

        public init(underlying: any Error, attempts: Int) {
            self.underlying = underlying
            self.attempts = attempts
        }

        public var description: String {
            "\(String(describing: underlying)) (after \(attempts) attempt\(attempts == 1 ? "" : "s"))"
        }
    }

    /// What went wrong, twice over: `cause` is a few words for the pill
    /// ("Timed out"), `detail` a sentence for the History row.
    public struct Summary: Sendable, Equatable {
        public let cause: String
        public let detail: String

        public init(cause: String, detail: String) {
            self.cause = cause
            self.detail = detail
        }
    }

    /// Runs `transcriber` under `policy`. `onAttemptFailed(attempt, error,
    /// seconds)` hears every failed attempt, retried or not.
    ///
    /// - Throws: ``Failure`` once every allowed attempt has failed (or the
    ///   first failure was not transient); `CancellationError` /
    ///   `URLError(.cancelled)` when the surrounding task is cancelled.
    public static func run(
        _ transcriber: any Transcriber,
        fileURL: URL,
        options: ScribeOptions,
        policy: Policy,
        onAttemptFailed: @escaping @Sendable (Int, any Error, TimeInterval) -> Void = { _, _, _ in }
    ) async throws -> Result {
        let attempts = max(1, policy.attempts)
        var attempt = 1
        while true {
            let started = ContinuousClock.now
            do {
                let response: ScribeResponse
                if let budget = policy.budget {
                    response = try await withTimeout(seconds: budget) {
                        try await transcriber.transcribe(fileURL: fileURL, options: options)
                    }
                } else {
                    response = try await transcriber.transcribe(fileURL: fileURL, options: options)
                }
                try Task.checkCancellation()
                return Result(response: response, seconds: seconds(since: started), attempts: attempt)
            } catch {
                if isCancellation(error) { throw error }
                if Task.isCancelled { throw CancellationError() }
                onAttemptFailed(attempt, error, seconds(since: started))
                guard attempt < attempts, isTransient(error) else {
                    throw Failure(underlying: error, attempts: attempt)
                }
            }
            attempt += 1
            if policy.retryDelay > 0 {
                try await Task.sleep(nanoseconds: UInt64(policy.retryDelay * 1_000_000_000))
            }
        }
    }

    /// Worth one more try: the request may well succeed a second later.
    /// Timeouts, network trouble, HTTP 408 / 429 / 5xx, a non-HTTP answer.
    /// Never a cancellation, a rejected key or request, or an answer that
    /// did not decode — those fail the same way twice.
    public static func isTransient(_ error: any Error) -> Bool {
        switch error {
        case is KleothTimeoutError:
            return true
        case let url as URLError:
            return transientURLCodes.contains(url.code)
        case let scribe as ScribeError:
            switch scribe {
            case .invalidResponse:
                return true
            case .httpError(let status, _):
                return status == 408 || status == 429 || (500...599).contains(status)
            }
        default:
            return false
        }
    }

    /// Esc, or a cancelled task: `CancellationError` from Swift concurrency,
    /// `URLError(.cancelled)` from URLSession — whichever wins the race.
    public static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        return false
    }

    /// The pill's few words and the History row's sentence for a failed run.
    /// A ``Failure`` is unwrapped to the error that ended it.
    public static func summary(of error: any Error, attempts: Int) -> Summary {
        let error = (error as? Failure)?.underlying ?? error
        let retried: String
        switch attempts {
        case ...1: retried = ""
        case 2: retried = " Tried twice."
        default: retried = " Tried \(attempts) times."
        }

        switch error {
        case let timeout as KleothTimeoutError:
            return Summary(
                cause: "Timed out",
                detail: "Scribe didn't answer within \(Int(timeout.seconds.rounded())) s.\(retried)"
            )
        case let url as URLError:
            switch url.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                return Summary(cause: "No internet connection", detail: "The Mac was offline.\(retried)")
            case .timedOut:
                return Summary(cause: "Timed out", detail: "The connection to Scribe timed out.\(retried)")
            case .networkConnectionLost:
                return Summary(cause: "Network error", detail: "The network connection was lost.\(retried)")
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .cannotLoadFromNetwork:
                return Summary(cause: "Network error", detail: "Couldn't reach Scribe.\(retried)")
            case .secureConnectionFailed:
                return Summary(cause: "Network error", detail: "A secure connection to Scribe couldn't be made.\(retried)")
            case .badServerResponse:
                return Summary(cause: "Network error", detail: "Scribe's server sent a bad response.\(retried)")
            default:
                return Summary(cause: "Network error", detail: "\(sentence(url.localizedDescription))\(retried)")
            }
        case let scribe as ScribeError:
            switch scribe {
            case .invalidResponse:
                return Summary(
                    cause: "Unreadable answer from Scribe",
                    detail: "Scribe's answer was not an HTTP response.\(retried)"
                )
            case .httpError(let status, let body):
                let server = serverMessage(in: body).map { " \(sentence($0))" } ?? ""
                switch status {
                case 401:
                    return Summary(
                        cause: "ElevenLabs rejected the key",
                        detail: "Scribe answered HTTP 401 — check the ElevenLabs key in Settings.\(server)"
                    )
                case 429:
                    return Summary(
                        cause: "Scribe is busy",
                        detail: "Scribe answered HTTP 429 (too many requests).\(server)\(retried)"
                    )
                case 500...599:
                    return Summary(cause: "Scribe error \(status)", detail: "Scribe answered HTTP \(status).\(server)\(retried)")
                default:
                    return Summary(cause: "Transcription failed (HTTP \(status))", detail: "Scribe answered HTTP \(status).\(server)")
                }
            }
        case is DecodingError:
            return Summary(cause: "Unreadable answer from Scribe", detail: "Scribe's answer couldn't be read.")
        default:
            let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return Summary(cause: "Transcription failed", detail: sentence(text))
        }
    }

    // MARK: - Private

    private static let transientURLCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
        .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed, .badServerResponse,
        .cannotLoadFromNetwork, .dataNotAllowed, .internationalRoamingOff,
    ]

    private static func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let elapsed = start.duration(to: .now)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    /// ElevenLabs puts the reason in `detail.message` (or `detail.status`, or a
    /// bare `detail` string). nil when the body says nothing useful.
    private static func serverMessage(in body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let detail = object["detail"]
        let text: String?
        if let nested = detail as? [String: Any] {
            text = (nested["message"] as? String) ?? (nested["status"] as? String)
        } else {
            text = detail as? String
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed.count > 200 ? String(trimmed.prefix(200)) + "…" : trimmed
    }

    /// One line ending in a full stop — not a second one after a closing
    /// parenthesis that already holds it ("… error -1000.)").
    private static func sentence(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard let last = line.last else { return line }
        if ".!?…".contains(last) || line.hasSuffix(".)") { return line }
        return line + "."
    }
}
