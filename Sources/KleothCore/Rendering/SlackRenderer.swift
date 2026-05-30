import Foundation

/// Renders a meeting summary into Slack-flavored markup suitable for
/// posting via an incoming webhook.
public enum SlackRenderer {
    public static func render(summary: MeetingSummary, metadata: MeetingMetadata) -> String {
        fatalError("unimplemented")
    }
}
