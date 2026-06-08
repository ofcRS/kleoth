import Foundation

/// Renders a meeting summary into Slack-flavored markup ("mrkdwn") suitable
/// for posting via an incoming webhook. Deliberately compact: title, TL;DR,
/// and the top action items — the detailed overview lives in the app/markdown.
public enum SlackRenderer {
    public static func render(summary: MeetingSummary, metadata: MeetingMetadata) -> String {
        var out = ""

        // Title
        out += "*\(esc(metadata.title))*\n\n"

        // TL;DR
        out += "*TL;DR*\n"
        out += "\(esc(summary.tldr))\n"

        // Action items — top 3, compact.
        out += "\n*Action items*\n"
        if summary.actionItems.isEmpty {
            out += "• _None_\n"
        } else {
            for item in summary.actionItems.prefix(3) {
                var line = "• \(mention(item.owner)) — \(esc(item.task))"
                if let due = item.due, !due.isEmpty {
                    line += " (due: \(esc(due)))"
                }
                out += line + "\n"
            }
        }

        return out
    }

    // MARK: - mrkdwn safety
    //
    // Title/tldr/owner/task are LLM-generated free text echoing meeting speech,
    // posted to a shared channel. Slack mrkdwn treats `&`, `<`, `>` as control
    // characters (link/command syntax like `<url|label>` / `<!channel>`), so they
    // must be escaped or a summary can inject links/formatting into the message.

    /// Escapes the three Slack mrkdwn control characters.
    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Renders an action-item owner as a cosmetic `@name`, escaped, and made
    /// inert against Slack broadcast pings: an owner of "channel"/"here"/
    /// "everyone" can't turn the literal `@` into an @channel-style broadcast.
    private static func mention(_ owner: String) -> String {
        let escaped = esc(owner)
        let broadcasts: Set<String> = ["channel", "here", "everyone"]
        if broadcasts.contains(owner.trimmingCharacters(in: .whitespaces).lowercased()) {
            // A zero-width space after @ keeps the look but prevents the broadcast.
            return "@\u{200B}\(escaped)"
        }
        return "@\(escaped)"
    }
}
