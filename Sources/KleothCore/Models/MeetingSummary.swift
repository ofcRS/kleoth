import Foundation

/// Structured summary of a meeting, produced by the summarizer.
public struct MeetingSummary: Codable, Sendable {
    public var tldr: String
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var keyPoints: [String]
    public var perSpeakerHighlights: [SpeakerHighlight]
    public var openQuestions: [String]
    public var suggestedTags: [String]

    public init(
        tldr: String,
        decisions: [String],
        actionItems: [ActionItem],
        keyPoints: [String],
        perSpeakerHighlights: [SpeakerHighlight],
        openQuestions: [String],
        suggestedTags: [String]
    ) {
        self.tldr = tldr
        self.decisions = decisions
        self.actionItems = actionItems
        self.keyPoints = keyPoints
        self.perSpeakerHighlights = perSpeakerHighlights
        self.openQuestions = openQuestions
        self.suggestedTags = suggestedTags
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
