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

        // Header: title, date, participants. The title is sanitized to one line
        // so an LLM- or rename-sourced newline (or leading `#`) can't split or
        // hijack the H1.
        out += "# \(singleLine(metadata.title))\n\n"
        let participants = metadata.participants.isEmpty
            ? "_None_"
            : metadata.participants.joined(separator: ", ")
        out += "*\(metadata.date)* — Participants: \(participants)\n\n"

        if let summary {
            // TL;DR
            out += "## TL;DR\n"
            out += "\(textOrNone(summary.tldr))\n\n"

            // Summary — the detailed narrative overview. Omitted (not "_None_")
            // when absent, so summaries from before the field existed don't
            // render an empty section.
            if let overview = summary.overview,
               !overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out += "## Summary\n"
                out += "\(overview)\n\n"
            }

            // Action Items
            out += "## Action Items\n"
            out += ActionItemsRenderer.render(summary)
            out += "\n\n"

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

    /// Collapses internal newlines/tabs to single spaces and trims, so a value
    /// rendered on a single Markdown line (e.g. the H1 title) can't break out of
    /// it. A leading `#` is stripped so a title can't escalate the heading.
    private static func singleLine(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed.drop(while: { $0 == "#" || $0 == " " }).trimmingCharacters(in: .whitespaces)
    }

    /// Formats a start time in seconds as `m:ss`. A nil time renders as `--`.
    private static func formatTimestamp(_ seconds: Double?) -> String {
        guard let seconds, seconds >= 0 else { return "--" }
        let total = Int(seconds.rounded(.down))
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
