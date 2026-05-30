import Foundation

/// A single contiguous run of speech attributed to one speaker.
public struct Utterance: Codable, Sendable {
    public var speakerId: String
    public var speakerName: String?
    public var start: Double?
    public var end: Double?
    public var text: String

    public init(
        speakerId: String,
        speakerName: String? = nil,
        start: Double? = nil,
        end: Double? = nil,
        text: String
    ) {
        self.speakerId = speakerId
        self.speakerName = speakerName
        self.start = start
        self.end = end
        self.text = text
    }
}

/// A normalized transcript: the diarized, speaker-grouped form of a
/// `ScribeResponse`, independent of single- vs. multi-channel input.
public struct Transcript: Codable, Sendable {
    public var utterances: [Utterance]
    public var languageCode: String?
    public var durationSecs: Double?

    public init(
        utterances: [Utterance],
        languageCode: String? = nil,
        durationSecs: Double? = nil
    ) {
        self.utterances = utterances
        self.languageCode = languageCode
        self.durationSecs = durationSecs
    }
}
