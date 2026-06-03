import SwiftUI
import KleothCore

/// Renders a meeting's structured `MeetingSummary` (and optional `Transcript`)
/// as native SwiftUI — not a Markdown string. The deliberate, lean reading
/// order: TL;DR → Summary (detailed overview) → Action Items → Per-Speaker
/// Highlights → Transcript. Empty sections are omitted entirely so a sparse
/// summary doesn't show a wall of "None" placeholders.
///
/// Each section lives in its own Kleoth content card (a `.regularMaterial`
/// rounded card with a hairline border — material, not glass) opened by a
/// `KleothSectionHeader` with an SF Symbol affordance, so the body reads with a
/// consistent rhythm. The on-disk `summary.md` / `transcript.md` are still
/// written by the pipeline for export and Copy-for-Slack; this view is the
/// in-app display surface.
struct MeetingSummaryView: View {
    let summary: MeetingSummary?
    let transcript: Transcript?

    var body: some View {
        VStack(alignment: .leading, spacing: KleothMetrics.spacingM) {
            if let summary {
                if let tldr = trimmed(summary.tldr) {
                    section("TL;DR", systemImage: "text.alignleft") {
                        Text(tldr)
                            .font(.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // The detailed narrative overview. Multi-paragraph prose (the
                // model separates paragraphs with blank lines, which Text
                // renders directly). Absent on summaries from before the field
                // existed — the section is simply omitted then.
                if let overview = trimmed(summary.overview) {
                    section("Summary", systemImage: "doc.text") {
                        Text(overview)
                            .font(.body)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !validActionItems(summary.actionItems).isEmpty {
                    section("Action Items", systemImage: "checklist") {
                        VStack(alignment: .leading, spacing: KleothMetrics.spacingM) {
                            ForEach(Array(validActionItems(summary.actionItems).enumerated()), id: \.offset) { _, item in
                                actionItemRow(item)
                            }
                        }
                    }
                }

                let highlights = validHighlights(summary.perSpeakerHighlights)
                if !highlights.isEmpty {
                    section("Per-Speaker Highlights", systemImage: "person.2.wave.2") {
                        VStack(alignment: .leading, spacing: KleothMetrics.spacingM) {
                            ForEach(Array(highlights.enumerated()), id: \.offset) { _, highlight in
                                VStack(alignment: .leading, spacing: KleothMetrics.spacingS) {
                                    HStack(spacing: KleothMetrics.spacingS) {
                                        SpeakerDot(
                                            color: KleothPalette.speakerColor(forSpeakerId: highlight.speaker, name: highlight.speaker),
                                            speakerName: highlight.speaker
                                        )
                                        Text(highlight.speaker)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .textSelection(.enabled)
                                    }
                                    bulletList(highlight.highlights)
                                }
                            }
                        }
                    }
                }

            }

            if let transcript, !transcript.utterances.isEmpty {
                section("Transcript", systemImage: "waveform") {
                    VStack(alignment: .leading, spacing: KleothMetrics.spacingM) {
                        ForEach(Array(transcript.utterances.enumerated()), id: \.offset) { _, utterance in
                            utteranceRow(utterance)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Section scaffolding

    /// A titled section rendered as a Kleoth content card: a `KleothSectionHeader`
    /// (accent SF Symbol + `.headline` title) above its content.
    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: KleothMetrics.spacingM) {
            KleothSectionHeader(title, systemImage: systemImage)
            content()
        }
        .kleothCard()
    }

    // MARK: - Rows

    /// A bulleted list of plain strings.
    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: KleothMetrics.spacingS) {
            ForEach(Array(nonEmpty(items).enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: KleothMetrics.spacingS) {
                    Text("•")
                        .foregroundStyle(.tertiary)
                    Text(item)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// An action item: an owner pill, the task text, and an optional due date.
    private func actionItemRow(_ item: ActionItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: KleothMetrics.spacingS) {
            if let owner = trimmed(item.owner) {
                KleothPill(owner, systemImage: "person", tint: .accentColor)
            }
            VStack(alignment: .leading, spacing: KleothMetrics.spacingXS) {
                Text(item.task)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let due = trimmed(item.due) {
                    Label("Due \(due)", systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A single transcript line in the "polished speaker card" layout: a colored
    /// speaker dot + the speaker name (semibold) + a monospaced `m:ss` timestamp
    /// on one line, with the utterance text below. You/Them are color-coded
    /// consistently via `KleothPalette.speakerColor`.
    private func utteranceRow(_ utterance: Utterance) -> some View {
        let color = KleothPalette.speakerColor(forSpeakerId: utterance.speakerId, name: utterance.speakerName)
        let name = utterance.speakerName ?? utterance.speakerId
        return VStack(alignment: .leading, spacing: KleothMetrics.spacingXS) {
            HStack(spacing: KleothMetrics.spacingS) {
                SpeakerDot(color: color, speakerName: name)
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(Self.timestamp(utterance.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(utterance.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
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
}