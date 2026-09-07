import Testing
import Foundation
@testable import KleothCore

@Suite struct TimeoutTests {
    @Test func returnsValueBeforeDeadline() async throws {
        let value = try await withTimeout(seconds: 5) { 42 }
        #expect(value == 42)
    }

    @Test func throwsKleothTimeoutErrorAfterDeadline() async {
        let started = Date()
        do {
            _ = try await withTimeout(seconds: 0.05) { () async throws -> Int in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            }
            Issue.record("Expected a timeout")
        } catch let error as KleothTimeoutError {
            #expect(error.seconds == 0.05)
            #expect(error.errorDescription?.contains("timed out") == true)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        // Must return promptly, not after the operation's own 5 s sleep.
        #expect(Date().timeIntervalSince(started) < 1.0)
    }

    @Test func cancelsTheLosingOperation() async {
        // Actor box so the operation can report back across the task boundary.
        actor Flag {
            private(set) var cancelled = false
            func mark() { cancelled = true }
        }
        let flag = Flag()

        do {
            _ = try await withTimeout(seconds: 0.05) { () async throws -> Int in
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    await flag.mark()
                    throw error
                }
                return 1
            }
            Issue.record("Expected a timeout")
        } catch is KleothTimeoutError {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // Give the cancelled child a moment to unwind and record the flag.
        for _ in 0..<50 {
            if await flag.cancelled { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await flag.cancelled)
    }
}

@Suite struct DeadlineTests {
    /// A completion-handler bridge: cancellation cannot cut it short, which is
    /// exactly the shape `withTimeout` fails to bound.
    private func uncancellable<T: Sendable>(after seconds: TimeInterval, value: T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                continuation.resume(returning: value)
            }
        }
    }

    @Test func returnsValueBeforeDeadline() async throws {
        let value = try await withDeadline(seconds: 5) { 42 }
        #expect(value == 42)
    }

    @Test func propagatesTheOperationsError() async {
        struct Boom: Error {}
        do {
            _ = try await withDeadline(seconds: 5) { () async throws -> Int in throw Boom() }
            Issue.record("Expected the operation's error")
        } catch is Boom {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func firesWithoutWaitingForANonCancellableOperation() async {
        let started = Date()
        do {
            _ = try await withDeadline(seconds: 0.05) { [self] () async throws -> Int in
                await uncancellable(after: 2, value: 1)
            }
            Issue.record("Expected a timeout")
        } catch let error as KleothTimeoutError {
            #expect(error.seconds == 0.05)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        // The whole point: it returns on the deadline, not on the operation.
        #expect(Date().timeIntervalSince(started) < 1.0)
    }

    @Test func outerCancellationEndsTheWaitPromptly() async {
        let task = Task { () async throws -> Int in
            try await withDeadline(seconds: 30) { [self] () async throws -> Int in
                await uncancellable(after: 2, value: 1)
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let started = Date()
        task.cancel()
        let result = await task.result
        switch result {
        case .success: Issue.record("Expected a cancellation")
        case .failure(let error): #expect(error is CancellationError)
        }
        #expect(Date().timeIntervalSince(started) < 1.0)
    }
}
