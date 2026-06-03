import Foundation

/// Renders a meeting summary into Slack-flavored markup ("mrkdwn") suitable
/// for posting via an incoming webhook. Deliberately compact: title, TL;DR,
/// and the top action items — the detailed overview lives in the app/markdown.
public enum SlackRenderer {
    public static func render(summary: MeetingSummary, metadata: MeetingMetadata) -> String {
        var out = ""

        // Title
        out += "*\(metadata.title)*\n\n"

        // TL;DR
        out += "*TL;DR*\n"
        out += "\(summary.tldr)\n"

        // Action items — top 3, compact.
        out += "\n*Action items*\n"
        if summary.actionItems.isEmpty {
            out += "• _None_\n"
        } else {
            for item in summary.actionItems.prefix(3) {
                var line = "• @\(item.owner) — \(item.task)"
                if let due = item.due, !due.isEmpty {
                    line += " (due: \(due))"
                }
                out += line + "\n"
            }
        }

        return out
    }
}
