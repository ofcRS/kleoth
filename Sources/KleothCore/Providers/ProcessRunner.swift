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
    /// the adapter decides what the output means.
    func run(
        executable: URL,
        arguments: [String],
        stdin: Data?,
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> ProcessResult
}

/// `Foundation.Process` behind ``ProcessRunner``. Both pipes are drained on
/// background tasks from the moment the process starts (a full pipe would
/// otherwise block the child forever), and termination is awaited through the
/// process's own `terminationHandler`.
public struct FoundationProcessRunner: ProcessRunner {
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
                // The first child to finish decides: exit status, or the
                // timeout's thrown error (which also terminated the process).
                guard let first = try await group.next() else { throw ProviderError.timedOut }
                group.cancelAll()
                return first
            }
        } onCancel: {
            box.terminate()
        }
        try Task.checkCancellation()
        return ProcessResult(stdout: await box.stdout(), stderr: await box.stderr(), status: status)
    }
}

/// Owns the `Process` and its pipes. `@unchecked Sendable`: every mutation
/// happens on `start` (before any concurrent access) or through Foundation's
/// own thread-safe `Process` API (`terminate`, `terminationHandler`).
private final class ProcessBox: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinPipe = Pipe()
    private var stdoutTask: Task<Data, Never>?
    private var stderrTask: Task<Data, Never>?
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
        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading
        stdoutTask = Task.detached { outHandle.readDataToEndOfFile() }
        stderrTask = Task.detached { errHandle.readDataToEndOfFile() }
        try process.run()
        let inHandle = stdinPipe.fileHandleForWriting
        if let stdin, !stdin.isEmpty {
            try? inHandle.write(contentsOf: stdin)
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
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    func stdout() async -> Data { await stdoutTask?.value ?? Data() }
    func stderr() async -> Data { await stderrTask?.value ?? Data() }
}
