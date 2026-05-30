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
        var out = ""

        // Header: title, date, participants.
        out += "# \(metadata.title)\n\n"
        let participants = metadata.participants.isEmpty
            ? "_None_"
            : metadata.participants.joined(separator: ", ")
        out += "*\(metadata.date)* — Participants: \(participants)\n\n"

        if let summary {
            // TL;DR
            out += "## TL;DR\n"
            out += "\(textOrNone(summary.tldr))\n\n"

            // Decisions
            out += "## Decisions\n"
            out += bulletedSection(summary.decisions)
            out += "\n"

            // Action Items
            out += "## Action Items\n"
            out += ActionItemsRenderer.render(summary)
            out += "\n\n"

            // Key Points
            out += "## Key Points\n"
            out += bulletedSection(summary.keyPoints)
            out += "\n"

            // Per-Speaker Highlights
            out += "## Per-Speaker Highlights\n"
            if summary.perSpeakerHighlights.isEmpty {
                out += "_None_\n"
            } else {
                for highlight in summary.perSpeakerHighlights {
                    out += "**\(highlight.speaker)**\n"
                    out += bulletedSection(highlight.highlights)
                }
            }
            out += "\n"

            // Open Questions
            out += "## Open Questions\n"
            out += bulletedSection(summary.openQuestions)
            out += "\n"

            // Tags
            out += "## Tags\n"
            if summary.suggestedTags.isEmpty {
                out += "_None_\n"
            } else {
                out += summary.suggestedTags
                    .map { "#\(tagSlug($0))" }
                    .joined(separator: " ")
                out += "\n"
            }
            out += "\n"
        }

        if includeTranscript {
            out += "## Transcript\n"
            if transcript.utterances.isEmpty {
                out += "_None_\n"
            } else {
                for utterance in transcript.utterances {
                    let name = utterance.speakerName ?? utterance.speakerId
                    let stamp = formatTimestamp(utterance.start)
                    out += "**\(name)** [\(stamp)]: \(utterance.text)\n"
                }
            }
            out += "\n"
        }

        return out
    }

    // MARK: - Helpers

    /// Renders a list as Markdown bullets, or `_None_` when empty.
    /// The returned string always ends with a trailing newline.
    private static func bulletedSection(_ items: [String]) -> String {
        guard !items.isEmpty else { return "_None_\n" }
        return items.map { "- \($0)" }.joined(separator: "\n") + "\n"
    }

    /// Returns the trimmed text, or `_None_` if it is empty/whitespace.
    private static func textOrNone(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "_None_" : text
    }

    /// Formats a start time in seconds as `m:ss`. A nil time renders as `--`.
    private static func formatTimestamp(_ seconds: Double?) -> String {
        guard let seconds, seconds >= 0 else { return "--" }
        let total = Int(seconds.rounded(.down))
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Converts an arbitrary tag string into a hashtag-friendly slug by
    /// collapsing whitespace to a single token.
    private static func tagSlug(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "-")
    }
}
