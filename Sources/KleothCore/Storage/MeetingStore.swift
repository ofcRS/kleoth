import Foundation

/// Persists meeting artifacts (raw response, transcript, summary, markdown,
/// speaker map, metadata) to a per-meeting directory under `baseDir`.
public struct MeetingStore {
    public let baseDir: URL

    public init(baseDir: URL) {
        self.baseDir = baseDir
    }

    /// Saves all artifacts for a meeting and returns the meeting directory.
    @discardableResult
    public func save(
        meetingName: String,
        raw: ScribeResponse?,
        transcript: Transcript,
        summary: MeetingSummary?,
        summaryMarkdown: String?,
        speakerMap: SpeakerMap?,
        metadata: MeetingMetadata
    ) throws -> URL {
        fatalError("unimplemented")
    }

    /// Loads the normalized transcript stored in `dir`.
    public func loadTranscript(in dir: URL) throws -> Transcript {
        fatalError("unimplemented")
    }

    /// Loads the summary stored in `dir`, if any.
    public func loadSummary(in dir: URL) throws -> MeetingSummary? {
        fatalError("unimplemented")
    }
}
