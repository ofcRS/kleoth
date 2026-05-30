import Foundation

/// Produces a structured `MeetingSummary` from a normalized transcript,
/// using an `OpenRouterClient`.
public struct Summarizer {
    public let client: OpenRouterClient
    public var model: String

    public init(client: OpenRouterClient, model: String = "anthropic/claude-haiku-4.5") {
        self.client = client
        self.model = model
    }

    /// Summarizes the transcript and returns the summary plus the USD cost
    /// of the completion.
    public func summarize(
        transcript: Transcript,
        metadata: MeetingMetadata
    ) async throws -> (summary: MeetingSummary, costUSD: Double) {
        fatalError("unimplemented")
    }
}
