import Foundation

/// Metadata describing a recorded meeting and its processing.
public struct MeetingMetadata: Codable, Sendable {
    public var title: String
    public var date: String
    public var participants: [String]
    public var consentAcknowledged: Bool
    public var model: String?
    public var languageCode: String?
    public var cost: CostBreakdown?

    public init(
        title: String,
        date: String,
        participants: [String] = [],
        consentAcknowledged: Bool = false,
        model: String? = nil,
        languageCode: String? = nil,
        cost: CostBreakdown? = nil
    ) {
        self.title = title
        self.date = date
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
