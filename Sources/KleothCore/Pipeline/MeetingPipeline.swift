import Foundation

/// End-to-end pipeline: transcribe an audio file, optionally summarize it,
/// and persist the results.
///
/// Fully wired in the Integrate phase.
public struct MeetingPipeline {
    public let scribe: ScribeClient
    public let summarizer: Summarizer?
    public let store: MeetingStore

    public init(scribe: ScribeClient, summarizer: Summarizer?, store: MeetingStore) {
        self.scribe = scribe
        self.summarizer = summarizer
        self.store = store
    }

    /// Runs the full pipeline for one meeting.
    public func run(
        audioFile: URL,
        metadata: MeetingMetadata,
        options: ScribeOptions,
        summarize: Bool
    ) async throws -> (transcript: Transcript, summary: MeetingSummary?, meetingDir: URL, cost: CostBreakdown) {
        fatalError("unimplemented")
    }
}
