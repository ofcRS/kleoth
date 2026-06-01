import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Options controlling an ElevenLabs Scribe transcription request.
public struct ScribeOptions: Sendable {
    public var modelId: String
    public var diarize: Bool
    public var numSpeakers: Int?
    public var languageCode: String?
    public var tagAudioEvents: Bool
    public var useMultiChannel: Bool

    public init(
        modelId: String = "scribe_v2",
        diarize: Bool = true,
        numSpeakers: Int? = nil,
        languageCode: String? = nil,
        tagAudioEvents: Bool = true,
        useMultiChannel: Bool = false
    ) {
        self.modelId = modelId
        self.diarize = diarize
        self.numSpeakers = numSpeakers
        self.languageCode = languageCode
        self.tagAudioEvents = tagAudioEvents
        self.useMultiChannel = useMultiChannel
    }
}

/// Client for the ElevenLabs Scribe batch speech-to-text endpoint.
///
/// POST `https://api.elevenlabs.io/v1/speech-to-text`, multipart/form-data,
/// authenticated with the raw key in the `xi-api-key` header.
public struct ScribeClient {
    public let apiKey: String
    public let transport: HTTPTransport
    public var baseURL: URL

    public init(
        apiKey: String,
        transport: HTTPTransport,
        baseURL: URL = URL(string: "https://api.elevenlabs.io")!
    ) {
        self.apiKey = apiKey
        self.transport = transport
        self.baseURL = baseURL
    }

    /// Transcribes the audio file at `fileURL` using the given options.
    ///
    /// Builds a `multipart/form-data` body on disk (so multi-gigabyte audio is
    /// never held in memory), POSTs it to `<baseURL>/v1/speech-to-text` with the
    /// raw key in the `xi-api-key` header, and decodes the JSON response.
    ///
    /// - Throws: ``ScribeError/invalidResponse`` if the response is not an
    ///   `HTTPURLResponse`; ``ScribeError/httpError(status:body:)`` for any
    ///   non-2xx status (with a snippet of the response body); a
    ///   `DecodingError` if the JSON cannot be decoded; or any file-system or
    ///   transport error encountered along the way.
    public func transcribe(
        fileURL: URL,
        options: ScribeOptions = .init()
    ) async throws -> ScribeResponse {
        // Assemble the multipart text fields.
        var fields: [String: String] = [
            "model_id": options.modelId,
            "tag_audio_events": options.tagAudioEvents ? "true" : "false",
        ]
        if options.useMultiChannel {
            // Multichannel mode assigns one speaker per channel and is mutually
            // exclusive with diarization / num_speakers — sending both makes
            // Scribe reject the request with HTTP 400.
            fields["use_multi_channel"] = "true"
        } else {
            fields["diarize"] = options.diarize ? "true" : "false"
            if let numSpeakers = options.numSpeakers {
                fields["num_speakers"] = String(numSpeakers)
            }
        }
        if let languageCode = options.languageCode {
            fields["language_code"] = languageCode
        }

        // Stream the body to a temporary file; clean it up no matter what.
        let (bodyURL, boundary) = try Multipart.writeBody(
            fields: fields,
            fileFieldName: "file",
            fileURL: fileURL,
            mimeType: Self.mimeType(for: fileURL)
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        // Build the request. Note: no Content-Length is set; URLSession derives
        // it from the upload file. Auth is the RAW key in xi-api-key.
        let endpoint = baseURL.appendingPathComponent("v1/speech-to-text")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        let (data, response) = try await transport.upload(for: request, fromFile: bodyURL)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ScribeError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ScribeError.httpError(
                status: httpResponse.statusCode,
                body: Self.bodySnippet(data)
            )
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ScribeResponse.self, from: data)
    }

    // MARK: - Helpers

    /// Maps a file extension to a MIME type for the multipart file part.
    static func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "aac": return "audio/aac"
        case "aiff", "aif": return "audio/aiff"
        case "flac": return "audio/flac"
        default: return "application/octet-stream"
        }
    }

    /// Returns a short, UTF-8 (best-effort) snippet of a response body for use
    /// in error messages. Truncated so error logs stay bounded.
    private static func bodySnippet(_ data: Data, limit: Int = 512) -> String {
        let slice = data.prefix(limit)
        let text = String(decoding: slice, as: UTF8.self)
        if data.count > limit {
            return text + "… (\(data.count) bytes total)"
        }
        return text
    }
}

extension ScribeClient: Transcriber {
    /// ElevenLabs Scribe batch pricing: USD 0.22 per hour of audio.
    public var usdPerHour: Double { 0.22 }
    // `transcribe(fileURL:options:)` already satisfies the protocol requirement.
}

/// Errors surfaced by ``ScribeClient``.
public enum ScribeError: Error, CustomStringConvertible, Sendable {
    /// The transport returned a non-HTTP response.
    case invalidResponse
    /// The server returned a non-2xx status code.
    case httpError(status: Int, body: String)

    public var description: String {
        switch self {
        case .invalidResponse:
            return "Scribe returned a non-HTTP response."
        case .httpError(let status, let body):
            return "Scribe request failed with HTTP \(status): \(body)"
        }
    }
}
