import Testing
import Foundation
@testable import KleothCore

/// What one scripted engine call does.
private enum Step: Sendable {
    case succeed(String)
    case fail(any Error)
    /// Sleeps far past any test budget — only a timeout or a cancel ends it.
    case hang
}

/// The calls a `ScriptedTranscriber` has served, and the ones still to come.
private actor Script {
    private var steps: [Step]
    private(set) var calls = 0

    init(_ steps: [Step]) { self.steps = steps }

    func next() -> Step {
        calls += 1
        return steps.isEmpty ? .fail(ScribeError.httpError(status: 418, body: "script exhausted")) : steps.removeFirst()
    }
}

/// An engine that replays a script: the retry policy under test never knows
/// it is not Scribe.
private struct ScriptedTranscriber: Transcriber {
    let script: Script
    var usdPerHour: Double { 0 }

    func transcribe(fileURL: URL, options: ScribeOptions) async throws -> ScribeResponse {
        switch await script.next() {
        case .succeed(let text):
            return ScribeResponse(text: text, languageCode: "eng")
        case .fail(let error):
            throw error
        case .hang:
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return ScribeResponse(text: "too late")
        }
    }
}

/// Collects `onAttemptFailed` reports across the `@Sendable` boundary.
private final class AttemptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [(attempt: Int, error: any Error)] = []

    func record(_ attempt: Int, _ error: any Error) {
        lock.lock(); defer { lock.unlock() }
        reports.append((attempt, error))
    }

    var attempts: [Int] {
        lock.lock(); defer { lock.unlock() }
        return reports.map(\.attempt)
    }

    var errors: [any Error] {
        lock.lock(); defer { lock.unlock() }
        return reports.map(\.error)
    }
}

/// The dictation Scribe policy (dictation-retry design §3.1): a budget that
/// grows with the clip, one retry after a transient failure, never a retry
/// after a cancellation.
@Suite struct DictationTranscriptionTests {
    private let clip = URL(fileURLWithPath: "/tmp/kleoth-test-clip.m4a")
    private let options = ScribeOptions.dictation(keyterms: [])
    /// Two attempts, a generous budget, no delay — fast tests of the retry rule itself.
    private let fastPolicy = DictationTranscription.Policy(attempts: 2, budget: 5, retryDelay: 0)

    // MARK: - Budget

    @Test func budgetGrowsWithTheClipAndIsCapped() {
        #expect(DictationDefaults.scribeBudget(forAudioSeconds: 0) == 25)
        #expect(DictationDefaults.scribeBudget(forAudioSeconds: 10) == 30)
        #expect(DictationDefaults.scribeBudget(forAudioSeconds: 41) == 45.5)
        #expect(DictationDefaults.scribeBudget(forAudioSeconds: 78) == 64)
        #expect(DictationDefaults.scribeBudget(forAudioSeconds: 190) == 120)
        #expect(DictationDefaults.scribeBudget(forAudioSeconds: 600) == 120)
        #expect(DictationDefaults.scribeBudget(forAudioSeconds: -3) == 25)
    }

    @Test func scribePolicyIsTwoAttemptsWithTheClipBudget() {
        let policy = DictationTranscription.Policy.scribe(audioSeconds: 78)
        #expect(policy == DictationTranscription.Policy(attempts: 2, budget: 64, retryDelay: 1))
        #expect(DictationTranscription.Policy.onDevice == DictationTranscription.Policy(attempts: 1, budget: nil, retryDelay: 0))
    }

    // MARK: - Retry rule

    @Test func firstAttemptSuccessIsOneAttempt() async throws {
        let script = Script([.succeed("hello")])
        let result = try await DictationTranscription.run(
            ScriptedTranscriber(script: script), fileURL: clip, options: options, policy: fastPolicy
        )
        #expect(result.response.text == "hello")
        #expect(result.attempts == 1)
        #expect(result.seconds >= 0)
        #expect(await script.calls == 1)
    }

    @Test func transientFailureIsRetriedOnce() async throws {
        let script = Script([.fail(URLError(.networkConnectionLost)), .succeed("second time")])
        let log = AttemptLog()
        let result = try await DictationTranscription.run(
            ScriptedTranscriber(script: script), fileURL: clip, options: options, policy: fastPolicy,
            onAttemptFailed: { attempt, error, _ in log.record(attempt, error) }
        )
        #expect(result.response.text == "second time")
        #expect(result.attempts == 2)
        #expect(await script.calls == 2)
        #expect(log.attempts == [1])
        #expect((log.errors.first as? URLError)?.code == .networkConnectionLost)
    }

    @Test func nonTransientFailureIsNotRetried() async {
        let script = Script([.fail(ScribeError.httpError(status: 401, body: "")), .succeed("never")])
        let log = AttemptLog()
        do {
            _ = try await DictationTranscription.run(
                ScriptedTranscriber(script: script), fileURL: clip, options: options, policy: fastPolicy,
                onAttemptFailed: { attempt, error, _ in log.record(attempt, error) }
            )
            Issue.record("Expected a failure")
        } catch let failure as DictationTranscription.Failure {
            #expect(failure.attempts == 1)
            guard case .httpError(let status, _)? = failure.underlying as? ScribeError else {
                Issue.record("Unexpected underlying error: \(failure.underlying)")
                return
            }
            #expect(status == 401)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await script.calls == 1)
        // The one failed attempt is still reported (it goes to the log).
        #expect(log.attempts == [1])
    }

    @Test func twoTransientFailuresThrowTheLastOne() async {
        let script = Script([.fail(URLError(.timedOut)), .fail(ScribeError.httpError(status: 503, body: ""))])
        do {
            _ = try await DictationTranscription.run(
                ScriptedTranscriber(script: script), fileURL: clip, options: options, policy: fastPolicy
            )
            Issue.record("Expected a failure")
        } catch let failure as DictationTranscription.Failure {
            #expect(failure.attempts == 2)
            guard case .httpError(let status, _)? = failure.underlying as? ScribeError else {
                Issue.record("Unexpected underlying error: \(failure.underlying)")
                return
            }
            #expect(status == 503)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await script.calls == 2)
    }

    @Test func aTimedOutAttemptIsRetried() async throws {
        let script = Script([.hang, .succeed("in time")])
        let log = AttemptLog()
        let started = Date()
        let result = try await DictationTranscription.run(
            ScriptedTranscriber(script: script), fileURL: clip, options: options,
            policy: DictationTranscription.Policy(attempts: 2, budget: 0.05, retryDelay: 0),
            onAttemptFailed: { attempt, error, _ in log.record(attempt, error) }
        )
        #expect(result.response.text == "in time")
        #expect(result.attempts == 2)
        #expect(log.errors.first is KleothTimeoutError)
        // Bounded by the budget, not by the hung call's own 30 s sleep.
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func noBudgetMeansNoTimeout() async throws {
        let script = Script([.succeed("slow but fine")])
        let result = try await DictationTranscription.run(
            ScriptedTranscriber(script: script), fileURL: clip, options: options, policy: .onDevice
        )
        #expect(result.response.text == "slow but fine")
        #expect(result.attempts == 1)
    }

    @Test func cancellationIsNeitherRetriedNorWrapped() async {
        let script = Script([.fail(CancellationError()), .succeed("never")])
        do {
            _ = try await DictationTranscription.run(
                ScriptedTranscriber(script: script), fileURL: clip, options: options, policy: fastPolicy
            )
            Issue.record("Expected the cancellation to propagate")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("Cancellation came back as \(error)")
        }
        #expect(await script.calls == 1)
    }

    /// Esc during the upload: URLSession reports the cancel as `URLError(.cancelled)`.
    @Test func urlSessionCancellationIsNotRetried() async {
        let script = Script([.fail(URLError(.cancelled)), .succeed("never")])
        do {
            _ = try await DictationTranscription.run(
                ScriptedTranscriber(script: script), fileURL: clip, options: options, policy: fastPolicy
            )
            Issue.record("Expected the cancellation to propagate")
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        } catch {
            Issue.record("Cancellation came back as \(error)")
        }
        #expect(await script.calls == 1)
    }

    @Test func cancellingTheRunStopsItWithoutARetry() async {
        let script = Script([.hang, .succeed("never")])
        let transcriber = ScriptedTranscriber(script: script)
        let clip = self.clip
        let options = self.options
        let task = Task {
            try await DictationTranscription.run(
                transcriber, fileURL: clip, options: options,
                policy: DictationTranscription.Policy(attempts: 2, budget: 10, retryDelay: 0)
            )
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let result = await task.result
        switch result {
        case .success:
            Issue.record("A cancelled run returned a transcript")
        case .failure(let error):
            #expect(DictationTranscription.isCancellation(error))
        }
        #expect(await script.calls == 1)
    }

    /// Esc during the pause before the second attempt: no second attempt,
    /// and the run ends at once rather than after the pause.
    @Test func cancellingDuringTheRetryPauseStopsTheRun() async {
        let script = Script([.fail(URLError(.networkConnectionLost)), .succeed("never")])
        let transcriber = ScriptedTranscriber(script: script)
        let clip = self.clip
        let options = self.options
        let started = Date()
        let task = Task {
            try await DictationTranscription.run(
                transcriber, fileURL: clip, options: options,
                policy: DictationTranscription.Policy(attempts: 2, budget: 5, retryDelay: 10)
            )
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let result = await task.result
        if case .success = result {
            Issue.record("A cancelled run returned a transcript")
        }
        if case .failure(let error) = result {
            #expect(DictationTranscription.isCancellation(error))
        }
        #expect(await script.calls == 1)
        #expect(Date().timeIntervalSince(started) < 2)
    }

    // MARK: - Classification

    @Test func transientErrorsAreTheOnesWorthASecondTry() {
        let transient: [any Error] = [
            KleothTimeoutError(seconds: 30),
            URLError(.timedOut), URLError(.networkConnectionLost), URLError(.notConnectedToInternet),
            URLError(.cannotConnectToHost), URLError(.cannotFindHost), URLError(.dnsLookupFailed),
            URLError(.secureConnectionFailed), URLError(.badServerResponse),
            URLError(.cannotLoadFromNetwork), URLError(.dataNotAllowed), URLError(.internationalRoamingOff),
            ScribeError.invalidResponse,
            ScribeError.httpError(status: 408, body: ""), ScribeError.httpError(status: 429, body: ""),
            ScribeError.httpError(status: 500, body: ""), ScribeError.httpError(status: 503, body: ""),
        ]
        for error in transient {
            #expect(DictationTranscription.isTransient(error), "\(error) should be transient")
        }
        let permanent: [any Error] = [
            CancellationError(), URLError(.cancelled), URLError(.badURL),
            ScribeError.httpError(status: 400, body: ""), ScribeError.httpError(status: 401, body: ""),
            ScribeError.httpError(status: 402, body: ""), ScribeError.httpError(status: 422, body: ""),
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad")),
        ]
        for error in permanent {
            #expect(!DictationTranscription.isTransient(error), "\(error) should not be retried")
        }
    }

    // MARK: - Copy

    @Test func summaryNamesTheCauseForThePillAndExplainsItForHistory() {
        let timeout = DictationTranscription.summary(of: KleothTimeoutError(seconds: 64), attempts: 2)
        #expect(timeout.cause == "Timed out")
        #expect(timeout.detail.contains("64 s"))
        #expect(timeout.detail.contains("twice"))

        let offline = DictationTranscription.summary(of: URLError(.notConnectedToInternet), attempts: 2)
        #expect(offline.cause == "No internet connection")

        #expect(DictationTranscription.summary(of: URLError(.networkConnectionLost), attempts: 2).cause == "Network error")
        #expect(DictationTranscription.summary(of: ScribeError.httpError(status: 401, body: ""), attempts: 1).cause
            == "ElevenLabs rejected the key")
        #expect(DictationTranscription.summary(of: ScribeError.httpError(status: 503, body: ""), attempts: 2).cause
            == "Scribe error 503")
        #expect(DictationTranscription.summary(of: ScribeError.httpError(status: 422, body: ""), attempts: 1).cause
            == "Transcription failed (HTTP 422)")
        #expect(DictationTranscription.summary(
            of: DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad")), attempts: 1
        ).cause == "Unreadable answer from Scribe")

        let busy = DictationTranscription.summary(
            of: ScribeError.httpError(
                status: 429,
                body: #"{"detail":{"status":"too_many_concurrent_requests","message":"Too many concurrent requests."}}"#
            ),
            attempts: 2
        )
        #expect(busy.cause == "Scribe is busy")
        #expect(busy.detail.contains("Too many concurrent requests."))
    }

    /// URLSession's own errors carry a localized sentence, but one built in
    /// code (or bridged without userInfo) reads "The operation couldn't be
    /// completed. (NSURLErrorDomain error -1005.)" — the row gets our words.
    @Test func networkSummariesAreSentencesOfOurOwn() {
        #expect(DictationTranscription.summary(of: URLError(.networkConnectionLost), attempts: 2).detail
            == "The network connection was lost. Tried twice.")
        #expect(DictationTranscription.summary(of: URLError(.cannotConnectToHost), attempts: 2).detail
            == "Couldn't reach Scribe. Tried twice.")
        #expect(DictationTranscription.summary(of: URLError(.cannotFindHost), attempts: 1).detail
            == "Couldn't reach Scribe.")
        #expect(DictationTranscription.summary(of: URLError(.secureConnectionFailed), attempts: 1).detail
            == "A secure connection to Scribe couldn't be made.")
        let other = DictationTranscription.summary(of: URLError(.badURL), attempts: 1).detail
        #expect(!other.hasSuffix(".)."))
    }

    @Test func summaryUnwrapsAFailure() {
        let failure = DictationTranscription.Failure(underlying: KleothTimeoutError(seconds: 30), attempts: 2)
        #expect(DictationTranscription.summary(of: failure, attempts: failure.attempts).cause == "Timed out")
    }
}
