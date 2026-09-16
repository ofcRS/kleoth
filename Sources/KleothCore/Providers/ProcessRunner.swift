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
    /// Runs `executable` to completion. `stdin` is written (off the caller's
    /// thread — a large payload to a child that never reads it must not
    /// block past the deadline) then closed. Throws `ProviderError.timedOut`
    /// after `timeout` seconds (the process is terminated), and
    /// `CancellationError` when the calling task is cancelled (likewise
    /// terminated). A non-zero exit is NOT an error here — the adapter
    /// decides what the output means. `run` always returns (or throws) — it
    /// never blocks forever, even if a grandchild the caller spawned
    /// inherits the pipes and never lets them see EOF.
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
        // Covers every exit below — success, `ProviderError.timedOut`, and a
        // cancellation throw alike — so a pending EOF that `collect` never
        // gets called to consume can't leave an armed dispatch source behind.
        defer { box.finish() }

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
/// own buffer (and its own handler-teardown state) with its own lock.
/// `start(stdin:)` must be called exactly once, before any other method — it
/// is the only place that spawns the process — and `finish()` must be called
/// on every exit path of the caller that started it, even one that never
/// reads output, so the pipe readers are always torn down deterministically.
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
        guard let stdin, !stdin.isEmpty else {
            try? inHandle.close()
            return
        }
        // Off the caller's (cooperative-pool) thread, and not awaited: a
        // payload bigger than the pipe's buffer (64 KiB) to a child that
        // never reads stdin would otherwise block here past the deadline —
        // the timeout task below only starts once `start` returns. Once
        // `terminate()` kills the child, the read end closes and this write
        // unblocks with EPIPE (SIGPIPE already disabled above), so the GCD
        // thread is released rather than leaked.
        let payload = stdin
        DispatchQueue.global().async {
            do {
                try inHandle.write(contentsOf: payload)
            } catch {
                // Expected when the child already exited, stopped reading, or
                // was terminated mid-write — not a failure of `run` itself.
            }
            try? inHandle.close()
        }
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

    /// Deterministically disarms both pipe readers, whether or not `collect`
    /// was ever called on them (e.g. a timed-out or cancelled `run` never
    /// calls `stdout`/`stderr`). Idempotent — safe to call after `collect`
    /// already finished a collector, and safe to call more than once.
    func finish() {
        stdoutCollector.finish()
        stderrCollector.finish()
    }
}

/// Drains one pipe's read end via `readabilityHandler` — a callback on
/// Foundation's own queue, never a blocking read on our task's thread — into
/// a lock-protected buffer. `collect(within:)` returns that buffer once EOF
/// is seen or a grace period elapses, whichever comes first: a grandchild
/// holding the write end open past the grace period just means collection
/// stops waiting, it never blocks the caller indefinitely.
///
/// Handler teardown is deterministic, not merely "eventually true": a
/// dispatch read source re-arms after every callback, so a pending EOF that
/// is never drained and disarmed fires the handler in a tight, CPU-spinning
/// loop. `finish()` is therefore reachable from three independent places —
/// EOF itself, `ProcessBox.finish()` (covering exits that never call
/// `collect` at all), and `deinit` — and the handler closure itself clears
/// and drains even when its `weak self` has already gone (the collector can
/// be released before EOF lands: the whole `ProcessBox` is torn down by a
/// `defer` on every exit path of `FoundationProcessRunner.run`).
private final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var isFinished = false
    private var eofWaiters: [() -> Void] = []
    private weak var handle: FileHandle?

    func start(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] fileHandle in
            // Drain unconditionally, before touching `self` — a `nil` self
            // must not skip clearing the handler, or this dispatch source
            // re-arms and fires again immediately with nothing to consume it.
            let chunk = fileHandle.availableData
            guard let self else {
                fileHandle.readabilityHandler = nil
                return
            }
            if chunk.isEmpty {
                self.finish()
            } else {
                self.lock.withLock { self.buffer.append(chunk) }
            }
        }
    }

    /// Clears the handler and marks the collector finished. Idempotent and
    /// safe from any thread/queue; the first caller wins and wakes anyone
    /// waiting in `collect`.
    func finish() {
        let (wasAlreadyFinished, waiters): (Bool, [() -> Void]) = lock.withLock {
            let already = isFinished
            isFinished = true
            let pending = already ? [] : eofWaiters
            eofWaiters.removeAll()
            return (already, pending)
        }
        handle?.readabilityHandler = nil
        if !wasAlreadyFinished {
            waiters.forEach { $0() }
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
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak self] in
                // The grace period is up: stop waiting AND disarm — a
                // grandchild may hold the pipe open for a long time still.
                self?.finish()
                resumeOnce.fire()
            }
        }
        return lock.withLock { buffer }
    }

    deinit {
        handle?.readabilityHandler = nil
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
