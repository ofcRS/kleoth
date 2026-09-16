import Foundation
@testable import KleothCore

/// Records every spawn and answers with canned results in order (last repeats).
final class MockProcessRunner: ProcessRunner, @unchecked Sendable {
    struct Call: Sendable {
        let executable: URL
        let arguments: [String]
        let stdin: Data?
        let environment: [String: String]
        let timeout: TimeInterval
        var stdinText: String? { stdin.map { String(decoding: $0, as: UTF8.self) } }
    }

    private let lock = NSLock()
    private let results: [Result<ProcessResult, Error>]
    private var index = 0
    private(set) var calls: [Call] = []

    init(results: [Result<ProcessResult, Error>]) {
        self.results = results
    }

    convenience init(stdout: String, status: Int32 = 0) {
        self.init(results: [.success(ProcessResult(stdout: Data(stdout.utf8), stderr: Data(), status: status))])
    }

    func run(executable: URL, arguments: [String], stdin: Data?, environment: [String: String], timeout: TimeInterval) async throws -> ProcessResult {
        let result: Result<ProcessResult, Error> = lock.withLock {
            calls.append(Call(executable: executable, arguments: arguments, stdin: stdin, environment: environment, timeout: timeout))
            let result = results[min(index, results.count - 1)]
            if index < results.count - 1 { index += 1 }
            return result
        }
        return try result.get()
    }
}
