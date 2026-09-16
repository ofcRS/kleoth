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
    }

    @Test func missingExecutableThrows() async {
        await #expect(throws: (any Error).self) {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/nonexistent/tool"), arguments: [],
                stdin: nil, environment: [:], timeout: 5)
        }
    }
}
