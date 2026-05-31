import Foundation

/// Metadata describing a recorded meeting and its processing.
public struct MeetingMetadata: Codable, Sendable {
    public var title: String
    public var date: String
    /// ISO-8601 datetime (with time) the recording/processing started. `nil` for
    /// legacy meetings saved before this field existed. Used to sort history and
    /// disambiguate multiple meetings recorded on the same calendar day.
    public var startedAt: String?
    public var participants: [String]
    public var consentAcknowledged: Bool
    public var model: String?
    public var languageCode: String?
    public var cost: CostBreakdown?

    public init(
        title: String,
        date: String,
        startedAt: String? = nil,
        participants: [String] = [],
        consentAcknowledged: Bool = false,
        model: String? = nil,
        languageCode: String? = nil,
        cost: CostBreakdown? = nil
    ) {
        self.title = title
        self.date = date
        self.startedAt = startedAt
        self.participants = participants
        self.consentAcknowledged = consentAcknowledged
        self.model = model
        self.languageCode = languageCode
        self.cost = cost
    }
}

/// USD cost breakdown for processing a single meeting.
public struct CostBreakdown: Codable, Sendable {
    public var transcriptionUSD: Double
    public var summaryUSD: Double
    public var audioDurationSecs: Double?

    public var totalUSD: Double {
        transcriptionUSD + summaryUSD
    }

    // Explicit, acronym-free coding keys. Under MeetingStore's snake_case key
    // strategies an all-caps suffix does NOT round-trip: `transcriptionUSD`
    // encodes (convertToSnakeCase) to `transcription_usd` but decodes
    // (convertFromSnakeCase) back to `transcriptionUsd`, which no longer matches
    // — so a saved `cost` could not be re-read. Mapping to acronym-free names
    // keeps encode/decode symmetric; on disk the keys are `transcription_cost` /
    // `summary_cost` / `audio_duration_secs`.
    // NOTE: any new stored property must be added to this enum too.
    enum CodingKeys: String, CodingKey {
        case transcriptionUSD = "transcriptionCost"
        case summaryUSD = "summaryCost"
        case audioDurationSecs
    }

    public init(
        transcriptionUSD: Double = 0,
        summaryUSD: Double = 0,
        audioDurationSecs: Double? = nil
    ) {
        self.transcriptionUSD = transcriptionUSD
        self.summaryUSD = summaryUSD
        self.audioDurationSecs = audioDurationSecs
    }
}
