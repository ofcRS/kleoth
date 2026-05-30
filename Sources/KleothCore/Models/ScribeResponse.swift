import Foundation

/// Top-level response from the ElevenLabs Scribe (batch STT) endpoint.
///
/// JSON arrives in snake_case; decode with
/// `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase` so the
/// camelCase properties below map automatically (no `CodingKeys`).
///
/// For single-channel input the transcript is delivered via `words`.
/// For multi-channel input (`use_multi_channel=true`) the top-level
/// `words` is omitted and `transcripts` is populated instead, one entry
/// per channel.
public struct ScribeResponse: Codable, Sendable {
    public var text: String?
    public var words: [ScribeWord]?
    public var transcripts: [ScribeChannelTranscript]?
    public var audioDurationSecs: Double?
    public var languageCode: String?
    public var transcriptionId: String?

    public init(
        text: String? = nil,
        words: [ScribeWord]? = nil,
        transcripts: [ScribeChannelTranscript]? = nil,
        audioDurationSecs: Double? = nil,
        languageCode: String? = nil,
        transcriptionId: String? = nil
    ) {
        self.text = text
        self.words = words
        self.transcripts = transcripts
        self.audioDurationSecs = audioDurationSecs
        self.languageCode = languageCode
        self.transcriptionId = transcriptionId
    }
}

/// A single token in a Scribe transcript.
///
/// `type` is one of `word`, `spacing`, or `audio_event`.
/// `speakerId` is present when diarization is enabled, e.g. `"speaker_0"`.
public struct ScribeWord: Codable, Sendable {
    public var text: String
    public var start: Double?
    public var end: Double?
    public var type: String?
    public var speakerId: String?
    public var logprob: Double?

    public init(
        text: String,
        start: Double? = nil,
        end: Double? = nil,
        type: String? = nil,
        speakerId: String? = nil,
        logprob: Double? = nil
    ) {
        self.text = text
        self.start = start
        self.end = end
        self.type = type
        self.speakerId = speakerId
        self.logprob = logprob
    }
}

/// One channel's transcript in a multi-channel Scribe response.
public struct ScribeChannelTranscript: Codable, Sendable {
    public var text: String?
    public var words: [ScribeWord]?
    public var channelIndex: Int?

    public init(
        text: String? = nil,
        words: [ScribeWord]? = nil,
        channelIndex: Int? = nil
    ) {
        self.text = text
        self.words = words
        self.channelIndex = channelIndex
    }
}
