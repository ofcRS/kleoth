import Foundation

/// Thrown by ``withTimeout(seconds:operation:)`` when the operation loses the
/// race against its deadline.
///
/// Dictation needs a real wall-clock budget on every network leg (25 s for
/// Scribe, 8 s for the polish call). `URLSessionTransport.defaultSession` uses a
/// 1200 s request timeout, so URLSession's own timeout would never save an
/// interactive dictation — this helper is the budget that actually fires.
public struct KleothTimeoutError: Error, Sendable, Equatable, LocalizedError {
    public let seconds: TimeInterval

    public init(seconds: TimeInterval) {
        self.seconds = seconds
    }

    public var errorDescription: String? {
        "The request timed out after \(Int(seconds)) s."
    }
}

/// Races `operation` against a sleep of `seconds`; whichever finishes first
/// wins, and the loser is cancelled.
///
/// Cancellation is cooperative but effective here: `URLSession`'s async APIs
/// honor task cancellation, so a timed-out request is actually torn down rather
/// than left running in the background.
///
/// Uses `withThrowingTaskGroup` + `Task.sleep(nanoseconds:)` so it builds on the
/// package's macOS 13 deployment floor (`ContinuousClock` sleeps need 13 too,
/// but the nanosecond form keeps this free of any clock-availability dance).
///
/// - Throws: `KleothTimeoutError` when the deadline wins; whatever `operation`
///   throws otherwise (including `CancellationError` when the surrounding task
///   is cancelled).
public func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
            throw KleothTimeoutError(seconds: seconds)
        }

        // Cancel the loser on every exit path (win, throw, outer cancellation).
        defer { group.cancelAll() }

        guard let first = try await group.next() else {
            // Unreachable: two child tasks were added above.
            throw KleothTimeoutError(seconds: seconds)
        }
        return first
    }
}
