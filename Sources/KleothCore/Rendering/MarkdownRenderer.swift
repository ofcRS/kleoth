import Foundation

/// Renders a meeting's summary, metadata, and (optionally) full transcript
/// to Markdown.
public enum MarkdownRenderer {
    public static func render(
        summary: MeetingSummary?,
        transcript: Transcript,
        metadata: MeetingMetadata,
        includeTranscript: Bool
    ) -> String {
        fatalError("unimplemented")
    }
}
