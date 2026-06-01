import SwiftUI
import KleothCore

/// Renders a meeting's structured `MeetingSummary` (and optional `Transcript`)
/// as native SwiftUI — not a Markdown string. Empty sections are omitted
/// entirely so a sparse summary doesn't show a wall of "None" placeholders.
///
/// The on-disk `summary.md` / `transcript.md` are still written by the pipeline
/// for export and Copy-for-Slack; this view is the in-app display surface.
struct MeetingSummaryView: View {
    let summary: MeetingSummary?
    let transcript: Transcript?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let summary {
                if let title = trimmed(summary.title) {
                    Text(title)
                        .font(.title2.bold())
                        .textSelection(.enabled)
                }

                if let tldr = trimmed(summary.tldr) {
                    section("TL;DR") {
                        Text(tldr)
                            .font(.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !nonEmpty(summary.decisions).isEmpty {
                    section("Decisions") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(nonEmpty(summary.decisions).enumerated()), id: \.offset) { _, decision in
                                iconRow("checkmark.seal", decision)
                            }
                        }
                    }
                }

                if !validActionItems(summary.actionItems).isEmpty {
                    section("Action Items") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(validActionItems(summary.actionItems).enumerated()), id: \.offset) { _, item in
                                actionItemRow(item)
                            }
                        }
                    }
                }

                if !nonEmpty(summary.keyPoints).isEmpty {
                    section("Key Points") {
                        bulletList(nonEmpty(summary.keyPoints))
                    }
                }

                let highlights = validHighlights(summary.perSpeakerHighlights)
                if !highlights.isEmpty {
                    section("Per-Speaker Highlights") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(highlights.enumerated()), id: \.offset) { _, highlight in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(highlight.speaker)
                                        .font(.subheadline.bold())
                                        .textSelection(.enabled)
                                    bulletList(highlight.highlights)
                                }
                            }
                        }
                    }
                }

                if !nonEmpty(summary.openQuestions).isEmpty {
                    section("Open Questions") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(nonEmpty(summary.openQuestions).enumerated()), id: \.offset) { _, question in
                                iconRow("questionmark.circle", question)
                            }
                        }
                    }
                }

                let tags = nonEmpty(summary.suggestedTags)
                if !tags.isEmpty {
                    section("Tags") {
                        tagChips(tags)
                    }
                }
            }

            if let transcript, !transcript.utterances.isEmpty {
                section("Transcript") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(transcript.utterances.enumerated()), id: \.offset) { _, utterance in
                            utteranceRow(utterance)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Section scaffolding

    /// A titled section with a `.headline` header and its content below.
    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Rows

    /// A bulleted list of plain strings.
    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(nonEmpty(items).enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text(item)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// A row led by an SF Symbol, with selectable text.
    private func iconRow(_ systemImage: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// An action item: an owner badge, the task text, and an optional due date.
    private func actionItemRow(_ item: ActionItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let owner = trimmed(item.owner) {
                Text(owner)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.task)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let due = trimmed(item.due) {
                    Text("Due \(due)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A single transcript line: speaker (bold), a monospaced m:ss timestamp,
    /// then the text.
    private func utteranceRow(_ utterance: Utterance) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(utterance.speakerName ?? utterance.speakerId)
                    .font(.subheadline.bold())
                Text(Self.timestamp(utterance.start))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(utterance.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Tags

    @ViewBuilder
    private func tagChips(_ tags: [String]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                Text("#\(Self.tagSlug(tag))")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    // MARK: - Filtering helpers

    /// Returns the trimmed string, or `nil` when empty/whitespace.
    private func trimmed(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Drops empty/whitespace-only entries from a list of strings.
    private func nonEmpty(_ items: [String]) -> [String] {
        items.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Action items that carry at least a task or an owner.
    private func validActionItems(_ items: [ActionItem]) -> [ActionItem] {
        items.filter { trimmed($0.task) != nil || trimmed($0.owner) != nil }
    }

    /// Speaker highlights that have at least one non-empty bullet.
    private func validHighlights(_ items: [SpeakerHighlight]) -> [SpeakerHighlight] {
        items.compactMap { highlight in
            let bullets = nonEmpty(highlight.highlights)
            guard !bullets.isEmpty else { return nil }
            return SpeakerHighlight(speaker: highlight.speaker, highlights: bullets)
        }
    }

    // MARK: - Formatting

    /// Formats a start time in seconds as `m:ss`; a nil time renders as `--`.
    private static func timestamp(_ seconds: Double?) -> String {
        guard let seconds, seconds >= 0 else { return "--" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Collapses whitespace in a tag into a single hashtag-friendly token.
    private static func tagSlug(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "-")
    }
}

// MARK: - Wrapping layout for tag chips

/// A minimal left-to-right wrapping layout: lays children out in rows, wrapping
/// to the next row when the proposed width is exceeded. Used for tag chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalWidth = max(totalWidth, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width - bounds.minX > maxWidth {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
