import Foundation
@testable import KleothCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A fully-canned `HTTPTransport` for tests: no live network is ever touched.
///
/// Configure it with one or more responses. Each call to `data(for:)` or
/// `upload(for:fromFile:)` consumes the next response in the sequence (FIFO).
/// This supports multi-step flows such as the summarizer's repair-retry path,
/// where the first completion returns bad JSON and the second returns good
/// JSON.
///
/// When the sequence is exhausted, the last configured response is replayed
/// (so a single-element sequence behaves like a constant transport). If no
/// responses were configured at all, any call throws `MockTransportError.exhausted`.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    /// One canned outcome: either bytes + response, or a thrown error.
    enum Outcome: Sendable {
        case success(Data, URLResponse)
        case failure(any Error)
    }

    private let lock = NSLock()
    private var outcomes: [Outcome]
    private var index = 0

    /// Captured requests in call order, for assertions about what was sent.
    private(set) var recordedRequests: [URLRequest] = []
    /// Captured upload source files, in call order (parallel to data/upload calls).
    private(set) var recordedUploadFiles: [URL?] = []

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    /// Convenience: a single 200 JSON response replayed for every call.
    convenience init(
        json: String,
        statusCode: Int = 200,
        url: URL = URL(string: "https://example.test/mock")!
    ) {
        let data = Data(json.utf8)
        let response = MockTransport.httpResponse(url: url, statusCode: statusCode)
        self.init(outcomes: [.success(data, response)])
    }

    /// Convenience: a sequence of JSON string bodies, each returned with the
    /// given status code, in order. Useful for bad-then-good repair flows.
    convenience init(
        jsonSequence: [String],
        statusCode: Int = 200,
        url: URL = URL(string: "https://example.test/mock")!
    ) {
        let outcomes = jsonSequence.map { body -> Outcome in
            .success(Data(body.utf8), MockTransport.httpResponse(url: url, statusCode: statusCode))
        }
        self.init(outcomes: outcomes)
    }

    // MARK: - HTTPTransport

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try next(request: request, uploadFile: nil)
    }

    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
        try next(request: request, uploadFile: fileURL)
    }

    // MARK: - Internals

    private func next(request: URLRequest, uploadFile: URL?) throws -> (Data, URLResponse) {
        lock.lock()
        defer { lock.unlock() }

        recordedRequests.append(request)
        recordedUploadFiles.append(uploadFile)

        guard !outcomes.isEmpty else {
            throw MockTransportError.exhausted
        }

        // Consume in order; replay the final outcome once exhausted.
        let outcome = outcomes[min(index, outcomes.count - 1)]
        if index < outcomes.count - 1 {
            index += 1
        }

        switch outcome {
        case let .success(data, response):
            return (data, response)
        case let .failure(error):
            throw error
        }
    }

    /// Number of requests served so far (data + upload combined).
    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests.count
    }

    // MARK: - Builders

    static func httpResponse(
        url: URL,
        statusCode: Int,
        headers: [String: String] = ["Content-Type": "application/json"]
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }
}

enum MockTransportError: Error, Sendable {
    /// No responses were configured for the transport.
    case exhausted
}
