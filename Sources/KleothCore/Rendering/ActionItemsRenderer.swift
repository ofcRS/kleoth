import Foundation

/// Renders just the action items of a summary as a Markdown checklist.
public enum ActionItemsRenderer {
    public static func render(_ summary: MeetingSummary) -> String {
        guard !summary.actionItems.isEmpty else {
            return "- [ ] _No action items_"
        }
        return summary.actionItems
            .map { item in
                var line = "- [ ] @\(item.owner) — \(item.task)"
                if let due = item.due, !due.isEmpty {
                    line += " (due: \(due))"
                }
                return line
            }
            .joined(separator: "\n")
    }
}
