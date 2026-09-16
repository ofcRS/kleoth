import Foundation

/// What a finished child process left behind.
public struct ProcessResult: Sendable, Equatable {
    public let stdout: Data
    public let stderr: Data
    public let status: Int32

    public init(stdout: Data, stderr: Data, status: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// The seam the CLI adapters spawn through. `FoundationProcessRunner` in the
/// app and probes; a recording mock in tests.
public protocol ProcessRunner: Sendable {
    /// Runs `executable` to completion. `stdin` is written then closed.
    /// Throws `ProviderError.timedOut` after `timeout` seconds (the process
    /// is terminated), and `CancellationError` when the calling task is
    /// cancelled (likewise terminated). A non-zero exit is NOT an error here —
    /// the adapter decides what the output means. `run` always returns (or
    /// throws) — it never blocks forever, even if a grandchild the caller
    /// spawned inherits the pipes and never lets them see EOF.
    func run(
        executable: URL,
        arguments: [String],
        stdin: Data?,
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> ProcessResult
}

/// `Foundation.Process` behind ``ProcessRunner``. Both pipes are drained by
/// `readabilityHandler` callbacks — Foundation's own background queue, never
/// a blocking read on the Swift Concurrency cooperative pool (blocking that
/// pool can starve the very timeout task that is supposed to bound this call)
/// — and termination is awaited through the process's own `terminationHandler`.
public struct FoundationProcessRunner: ProcessRunner {
    /// After the child exits (or is terminated), how long to keep waiting for
    /// EOF on the pipes before returning whatever has been read so far. A
    /// grandchild with inherited stdio (what `claude`/`codex` may spawn) can
    /// hold a pipe open long after the process we actually waited on has
    /// exited; this bounds that wait so `run` always returns.
    private static let outputGracePeriod: TimeInterval = 1.0

    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        stdin: Data?,
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        let box = ProcessBox(executable: executable, arguments: arguments, environment: environment)
        try box.start(stdin: stdin)

        let status: Int32 = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask { await box.waitForExit() }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    box.terminate()
                    throw ProviderError.timedOut
                }
                // Exactly two tasks were just added, so the first result is
                // never nil — either the exit status, or the timeout task's
                // thrown error (which also terminated the process).
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } onCancel: {
            box.terminate()
        }
        try Task.checkCancellation()
        // Collected in parallel, each bounded by its own grace period — a
        // slow/held-open stderr must not add to stdout's wait.
        async let stdoutData = box.stdout(within: Self.outputGracePeriod)
        async let stderrData = box.stderr(within: Self.outputGracePeriod)
        return ProcessResult(stdout: await stdoutData, stderr: await stderrData, status: status)
    }
}

/// Owns the `Process`, its three pipes, and the two output collectors.
/// `@unchecked Sendable`: `process`/the pipes are configured once in `init`
/// and thereafter only driven through Foundation's own thread-safe `Process`
/// API (`run`, `terminate`, `terminationHandler`, `isRunning`); the mutable
/// exit-resume flag is behind `exitLock`, and each `PipeCollector` guards its
/// own buffer with its own lock. `start(stdin:)` must be called exactly once,
/// before any other method — it is the only place that spawns the process.
private final class ProcessBox: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinPipe = Pipe()
    private let stdoutCollector = PipeCollector()
    private let stderrCollector = PipeCollector()
    private let exitLock = NSLock()
    private var resumed = false

    init(executable: URL, arguments: [String], environment: [String: String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe
    }

    func start(stdin: Data?) throws {
        stdoutCollector.start(handle: stdoutPipe.fileHandleForReading)
        stderrCollector.start(handle: stderrPipe.fileHandleForReading)

        try process.run()

        let inHandle = stdinPipe.fileHandleForWriting
        // A child that exits before reading all of stdin (e.g. an
        // unauthenticated `claude -p` that fails in milliseconds) delivers
        // SIGPIPE on write, which by default kills THIS process, not just the
        // write call — `try?` is no protection, the signal fires inside
        // write(2) before it can return an error. Disable SIGPIPE delivery on
        // the write end instead, so a failed write throws EPIPE like a normal
        // error.
        _ = fcntl(inHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
        if let stdin, !stdin.isEmpty {
            do {
                try inHandle.write(contentsOf: stdin)
            } catch {
                // Expected when the child already exited or stopped reading —
                // not a failure of `run` itself.
            }
        }
        try? inHandle.close()
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            if !process.isRunning {
                resumeOnce(continuation, process.terminationStatus)
                return
            }
            process.terminationHandler = { finished in
                self.resumeOnce(continuation, finished.terminationStatus)
            }
            // The handler is installed after `run()`; if the process exited in
            // between, the handler never fires — re-check.
            if !process.isRunning {
                process.terminationHandler = nil
                resumeOnce(continuation, process.terminationStatus)
            }
        }
    }

    private func resumeOnce(_ continuation: CheckedContinuation<Int32, Never>, _ status: Int32) {
        exitLock.lock()
        defer { exitLock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: status)
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        // SIGTERM is polite; a stuck child gets SIGKILL two seconds later.
        // Re-read `processIdentifier`/`isRunning` at fire time rather than
        // capturing the pid now — a pid captured up front could, in
        // principle, have been reaped and reused by the time this fires.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            guard process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }

    func stdout(within grace: TimeInterval) async -> Data { await stdoutCollector.collect(within: grace) }
    func stderr(within grace: TimeInterval) async -> Data { await stderrCollector.collect(within: grace) }
}

/// Drains one pipe's read end via `readabilityHandler` — a callback on
/// Foundation's own queue, never a blocking read on our task's thread — into
/// a lock-protected buffer. `collect(within:)` returns that buffer once EOF
/// is seen or a grace period elapses, whichever comes first: a grandchild
/// holding the write end open past the grace period just means collection
/// stops waiting, it never blocks the caller indefinitely.
private final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var isFinished = false
    private var eofWaiters: [() -> Void] = []

    func start(handle: FileHandle) {
        handle.readabilityHandler = { [weak self] fileHandle in
            guard let self else { return }
            let chunk = fileHandle.availableData
            if chunk.isEmpty {
                let waiters: [() -> Void] = self.lock.withLock {
                    self.isFinished = true
                    let pending = self.eofWaiters
                    self.eofWaiters.removeAll()
                    return pending
                }
                fileHandle.readabilityHandler = nil
                waiters.forEach { $0() }
            } else {
                self.lock.withLock { self.buffer.append(chunk) }
            }
        }
    }

    func collect(within grace: TimeInterval) async -> Data {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeOnce = ResumeVoidOnce(continuation)
            let alreadyFinished = lock.withLock { isFinished }
            if alreadyFinished {
                resumeOnce.fire()
                return
            }
            lock.withLock { eofWaiters.append { resumeOnce.fire() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) { resumeOnce.fire() }
        }
        return lock.withLock { buffer }
    }
}

/// Resumes a `Void` continuation exactly once, whichever caller — EOF or the
/// grace-period timer — gets there first. The loser's callback becomes a
/// harmless no-op.
private final class ResumeVoidOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let continuation: CheckedContinuation<Void, Never>

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func fire() {
        let shouldResume = lock.withLock {
            guard !fired else { return false }
            fired = true
            return true
        }
        if shouldResume { continuation.resume() }
    }
}
