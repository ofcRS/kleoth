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
/// - Important: this bounds only work that HONORS cancellation. A task group
///   does not return until every child has finished, so around a
///   completion-handler bridge (`AVAssetWriter.finishWriting`,
///   `SCShareableContent`) the deadline error surfaces only once the operation
///   finally lands — the "timeout" is then a label, not a bound. Use
///   ``withDeadline(seconds:operation:)`` for those.
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

/// Races `operation` against a deadline WITHOUT waiting for the operation.
///
/// ``withTimeout(seconds:operation:)`` is a task group, and a group only returns
/// once every child has finished — so it cannot bound work that ignores
/// cancellation. Completion-handler bridges do exactly that
/// (`AVAssetWriter.finishWriting` resumes its continuation whenever the file is
/// closed; `SCShareableContent` answers whenever TCC lets it), and a
/// `withTimeout` around one blocks its caller for the operation's full duration.
///
/// This helper resumes on whichever lands first and leaves a losing operation
/// running in an unstructured task. The caller therefore owns whatever that work
/// still does when it completes later (e.g. `ScreenRecorder.stop` gives a
/// late-but-successful finalize its final filename in the background).
///
/// - Throws: `KleothTimeoutError` when the deadline wins, `CancellationError`
///   when the surrounding task is cancelled, whatever `operation` throws
///   otherwise.
public func withDeadline<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let box = DeadlineBox<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            box.install(continuation)
            box.startDeadline(seconds: seconds)
            Task {
                do {
                    box.settle(.success(try await operation()))
                } catch {
                    box.settle(.failure(error))
                }
            }
        }
    } onCancel: {
        box.settle(.failure(CancellationError()))
    }
}

/// One-shot continuation holder for ``withDeadline(seconds:operation:)``.
///
/// `@unchecked Sendable` over an `NSLock`: the racers run on unrelated
/// executors, and `onCancel` can even fire BEFORE the continuation is installed
/// (an already-cancelled task) — hence the pending slot.
private final class DeadlineBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var settled = false
    private var deadlineTask: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let pending {
            self.pending = nil
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func startDeadline(seconds: TimeInterval) {
        let task = Task { [weak self] in
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return  // the race is already over
            }
            self?.settle(.failure(KleothTimeoutError(seconds: seconds)))
        }
        lock.lock()
        let alreadySettled = settled
        if !alreadySettled { deadlineTask = task }
        lock.unlock()
        if alreadySettled { task.cancel() }
    }

    func settle(_ result: Result<T, Error>) {
        lock.lock()
        guard !settled else {
            lock.unlock()
            return
        }
        settled = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { pending = result }
        let deadlineTask = self.deadlineTask
        self.deadlineTask = nil
        lock.unlock()
        deadlineTask?.cancel()
        continuation?.resume(with: result)
    }
}
