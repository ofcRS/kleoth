import Foundation

/// Structured summary of a meeting, produced by the summarizer.
///
/// Deliberately lean: a TL;DR, a detailed narrative overview, action items, and
/// per-speaker highlights. Earlier shapes also carried decisions / key points /
/// open questions / suggested tags; those read as generated filler and were
/// removed (2026-06-04). Old `summary.json` files that still contain them decode
/// fine — the extra keys are simply ignored.
public struct MeetingSummary: Codable, Sendable {
    /// A concise, specific meeting title produced by the summarizer. Optional so
    /// summaries written before this field existed still decode, and so call
    /// sites that don't supply one keep compiling.
    public var title: String?
    /// 2–4 sentences capturing the essence of the meeting.
    public var tldr: String
    /// The detailed, multi-paragraph prose overview of the whole meeting — what
    /// was discussed and in what order, with concrete specifics. Surfaced as the
    /// "Summary" section. Optional: files written before the field existed lack it.
    public var overview: String?
    public var actionItems: [ActionItem]
    public var perSpeakerHighlights: [SpeakerHighlight]

    public init(
        title: String? = nil,
        tldr: String,
        overview: String? = nil,
        actionItems: [ActionItem] = [],
        perSpeakerHighlights: [SpeakerHighlight] = []
    ) {
        self.title = title
        self.tldr = tldr
        self.overview = overview
        self.actionItems = actionItems
        self.perSpeakerHighlights = perSpeakerHighlights
    }

    // All key names are acronym-free, so they round-trip under MeetingStore's
    // snake_case strategies (`action_items` / `per_speaker_highlights`).
    enum CodingKeys: String, CodingKey {
        case title, tldr, overview, actionItems, perSpeakerHighlights
    }

    /// Lenient decoding: `tldr` is the one hard requirement (a summary without it
    /// is unusable and should fail into the repair path); everything else is
    /// optional so older files and a provider's looser `json_object` fallback
    /// still decode, with the arrays defaulting to empty.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        tldr = try container.decode(String.self, forKey: .tldr)
        overview = try container.decodeIfPresent(String.self, forKey: .overview)
        actionItems = try container.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        perSpeakerHighlights = try container.decodeIfPresent(
            [SpeakerHighlight].self, forKey: .perSpeakerHighlights
        ) ?? []
    }
}

/// A single action item with an owner, the task, and an optional due date.
public struct ActionItem: Codable, Sendable {
    public var owner: String
    public var task: String
    public var due: String?

    public init(owner: String, task: String, due: String? = nil) {
        self.owner = owner
        self.task = task
        self.due = due
    }
}

/// Highlights attributed to a single speaker.
public struct SpeakerHighlight: Codable, Sendable {
    public var speaker: String
    public var highlights: [String]

    public init(speaker: String, highlights: [String]) {
        self.speaker = speaker
        self.highlights = highlights
    }
}
