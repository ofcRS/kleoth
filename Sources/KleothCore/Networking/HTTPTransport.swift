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

    /// Uploads `fileURL` as the request body, reporting fractional send progress
    /// (0…1) via `progress` as bytes leave the machine. A `nil` `progress` is
    /// equivalent to ``upload(for:fromFile:)``. Has a default implementation that
    /// forwards to ``upload(for:fromFile:)`` (ignoring progress), so conformers
    /// that don't track progress — e.g. test fakes — need not implement it.
    func upload(
        for request: URLRequest,
        fromFile fileURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> (Data, URLResponse)
}

public extension HTTPTransport {
    func upload(
        for request: URLRequest,
        fromFile fileURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> (Data, URLResponse) {
        try await upload(for: request, fromFile: fileURL)
    }
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

    public func upload(
        for request: URLRequest,
        fromFile fileURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> (Data, URLResponse) {
        guard let progress else {
            return try await session.upload(for: request, fromFile: fileURL)
        }
        // A per-task delegate reports bytes-sent as the body streams to the
        // server. Scribe then transcribes server-side with no further progress,
        // so callers treat reaching 1.0 as the switch to an indeterminate phase.
        let delegate = UploadProgressDelegate(onProgress: progress)
        return try await session.upload(for: request, fromFile: fileURL, delegate: delegate)
    }
}

/// Forwards a `URLSession` upload task's send progress to a callback. The
/// delegate methods arrive on the session's delegate queue, so `onProgress`
/// must itself hop to whatever actor it needs (the app wraps it in a main-actor
/// `Task`). `@unchecked Sendable`: it holds only an immutable `@Sendable`
/// closure and `URLSession` serializes the callbacks for a given task.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        onProgress(min(max(fraction, 0), 1))
    }
}
