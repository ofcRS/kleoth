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

    /// Defaults to ``defaultSession`` (tuned for large audio uploads); inject a
    /// custom session for tests or special cases.
    public init(session: URLSession = URLSessionTransport.defaultSession) {
        self.session = session
    }

    /// A session tuned for transcription traffic. ElevenLabs Scribe holds the
    /// connection open while it transcribes server-side, so the per-request
    /// timeout — the gap allowed *between bytes* — must be far larger than the
    /// 60-second `URLSession.shared` default. With the default, a long
    /// recording's upload "times out" mid-transcription (`NSURLErrorTimedOut`,
    /// "The request timed out") and the meeting is lost even though the audio is
    /// safe on disk. 20 minutes comfortably covers Scribe processing a
    /// multi-hour file; the resource ceiling stays at its large default.
    public static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 1200   // 20 min between bytes (was 60s)
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    public func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
        try await session.upload(for: request, fromFile: fileURL)
    }
}
