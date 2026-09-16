import Testing
import Foundation
@testable import KleothCore

@Suite struct ProcessRunnerTests {
    let runner = FoundationProcessRunner()

    @Test func capturesStdoutAndStatus() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["hello"],
            stdin: nil, environment: [:], timeout: 5)
        #expect(result.stdoutText == "hello\n")
        #expect(result.status == 0)
    }

    @Test func feedsStdinAndCapturesStderr() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "cat; echo oops 1>&2; exit 3"],
            stdin: Data("payload".utf8), environment: [:], timeout: 5)
        #expect(result.stdoutText == "payload")
        #expect(result.stderrText == "oops\n")
        #expect(result.status == 3)
    }

    @Test func timeoutTerminatesTheProcess() async throws {
        let started = Date()
        await #expect(throws: ProviderError.timedOut) {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                stdin: nil, environment: [:], timeout: 0.3)
        }
        #expect(Date().timeIntervalSince(started) < 5)
        // Prove the runner itself is not wedged by the terminated child.
        try await Task.sleep(for: .milliseconds(100))
        let followUp = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["ok"],
            stdin: nil, environment: [:], timeout: 5)
        #expect(followUp.stdoutText == "ok\n")
    }

    @Test func cancellationTerminatesTheProcess() async throws {
        let started = Date()
        let task = Task {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                stdin: nil, environment: [:], timeout: 60)
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(started) < 5)
        // Prove the runner itself is not wedged by the cancelled child.
        try await Task.sleep(for: .milliseconds(100))
        let followUp = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["ok"],
            stdin: nil, environment: [:], timeout: 5)
        #expect(followUp.stdoutText == "ok\n")
    }

    @Test func missingExecutableThrows() async {
        await #expect(throws: (any Error).self) {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/nonexistent/tool"), arguments: [],
                stdin: nil, environment: [:], timeout: 5)
        }
    }

    /// A child that exits without reading all of stdin (an unauthenticated
    /// `claude -p` fails in milliseconds) must not deliver SIGPIPE to the
    /// test process on write — that would kill the whole test run, not just
    /// this one call.
    @Test func stdinToAnExitedChildDoesNotKillTheHost() async throws {
        let payload = Data(repeating: 0x61, count: 1 << 20)
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"],
            stdin: payload, environment: [:], timeout: 5)
        #expect(result.status == 0)
        // Reaching this line at all proves the host survived the write.
    }

    /// A grandchild that inherits the pipes (what `claude`/`codex` may spawn)
    /// and outlives the process we waited on must not hold `run` open until
    /// the grandchild itself exits.
    @Test func grandchildHoldingThePipeDoesNotHangRun() async throws {
        let started = Date()
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30 & echo hi"],
            stdin: nil, environment: [:], timeout: 5)
        #expect(result.stdoutText == "hi\n")
        #expect(Date().timeIntervalSince(started) < 3)
    }
}
