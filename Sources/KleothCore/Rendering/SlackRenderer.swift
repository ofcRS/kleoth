import Foundation

/// Renders a meeting summary into Slack-flavored markup ("mrkdwn") suitable
/// for posting via an incoming webhook.
public enum SlackRenderer {
    public static func render(summary: MeetingSummary, metadata: MeetingMetadata) -> String {
        var out = ""

        // Title
        out += "*\(metadata.title)*\n\n"

        // TL;DR
        out += "*TL;DR*\n"
        out += "\(summary.tldr)\n\n"

        // Decisions — top 3, compact.
        out += "*Decisions*\n"
        out += slackBullets(Array(summary.decisions.prefix(3)))

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

    // MARK: - Helpers

    /// Renders a list as Slack `•` bullets, or `• _None_` when empty.
    /// Always ends with a trailing newline.
    private static func slackBullets(_ items: [String]) -> String {
        guard !items.isEmpty else { return "• _None_\n" }
        return items.map { "• \($0)" }.joined(separator: "\n") + "\n"
    }
}
