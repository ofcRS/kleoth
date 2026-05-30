import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Abstraction over the HTTP layer so clients can be tested against a
/// fake transport without hitting the network.
public protocol HTTPTransport: Sendable {
    /// Performs the request and returns the response body and metadata.
    func data(for request: URLRequest) async throws -> (Data, URLResponse)

    /// Uploads the contents of `fileURL` as the body of `request`.
    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse)
}

/// Production `HTTPTransport` backed by `URLSession`.
public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    public func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
        try await session.upload(for: request, fromFile: fileURL)
    }
}
