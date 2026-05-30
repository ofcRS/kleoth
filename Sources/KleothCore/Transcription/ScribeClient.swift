import Foundation

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
    public func transcribe(
        fileURL: URL,
        options: ScribeOptions = .init()
    ) async throws -> ScribeResponse {
        fatalError("unimplemented")
    }
}
