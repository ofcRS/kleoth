import Testing
@testable import KleothCore

@Suite struct RendererTests {
    // MARK: - Fixtures

    private func sampleSummary() -> MeetingSummary {
        MeetingSummary(
            tldr: "We shipped the beta and picked a launch date.",
            overview: "The team walked through the beta rollout, reviewed feedback, and agreed to launch on June 10.\n\nAlice took the changelog; Bob will email the beta list.",
            actionItems: [
                ActionItem(owner: "alice", task: "Finalize the changelog", due: "2026-06-05"),
                ActionItem(owner: "bob", task: "Email the beta list", due: nil),
            ],
            perSpeakerHighlights: [
                SpeakerHighlight(speaker: "Alice", highlights: ["Owns the changelog"]),
            ]
        )
    }

    private func sampleMetadata() -> MeetingMetadata {
        MeetingMetadata(
            title: "Launch Planning",
            date: "2026-05-30",
            participants: ["Alice", "Bob"],
            consentAcknowledged: true
        )
    }

    private func sampleTranscript() -> Transcript {
        Transcript(
            utterances: [
                Utterance(speakerId: "speaker_0", speakerName: "Alice", start: 0.0, end: 2.0, text: "Hi everyone"),
                Utterance(speakerId: "speaker_1", speakerName: "Bob", start: 2.5, end: 4.0, text: "Hello"),
            ],
            languageCode: "en",
            durationSecs: 4.0
        )
    }

    // MARK: - MarkdownRenderer

    @Test func markdownContainsRequiredHeaders() {
        let md = MarkdownRenderer.render(
            summary: sampleSummary(),
            transcript: sampleTranscript(),
            metadata: sampleMetadata(),
            includeTranscript: false
        )

        #expect(md.contains("## TL;DR"), "Missing TL;DR header in:\n\(md)")
        #expect(md.contains("## Summary"), "Missing Summary header in:\n\(md)")
        #expect(md.contains("## Action Items"), "Missing Action Items header in:\n\(md)")
        #expect(md.contains("## Per-Speaker Highlights"))
        // The overview's prose lands under Summary.
        #expect(md.contains("agreed to launch on June 10"))
        // Removed sections must not come back.
        #expect(!md.contains("## Decisions"))
        #expect(!md.contains("## Key Points"))
        #expect(!md.contains("## Open Questions"))
        #expect(!md.contains("## Tags"))
        // Title header.
        #expect(md.contains("# Launch Planning"))
    }

    /// A title with embedded newlines (LLM- or rename-sourced) is collapsed to a
    /// single line so it can't split or escalate the Markdown H1.
    @Test func markdownTitleIsCollapsedToOneLine() {
        let metadata = MeetingMetadata(
            title: "Line one\nLine two\n# sneaky",
            date: "2026-05-30",
            participants: [],
            consentAcknowledged: true
        )
        let md = MarkdownRenderer.render(
            summary: nil,
            transcript: sampleTranscript(),
            metadata: metadata,
            includeTranscript: false
        )
        #expect(md.hasPrefix("# Line one Line two # sneaky\n"))
        // The embedded newlines were collapsed — no stray heading lines.
        #expect(!md.contains("\nLine two"))
        #expect(!md.contains("\n# sneaky"))
    }

    /// Legacy summaries (no overview) skip the Summary section instead of
    /// rendering an empty one.
    @Test func markdownOmitsSummarySectionWithoutOverview() {
        var legacy = sampleSummary()
        legacy.overview = nil
        let md = MarkdownRenderer.render(
            summary: legacy,
            transcript: sampleTranscript(),
            metadata: sampleMetadata(),
            includeTranscript: false
        )
        #expect(!md.contains("## Summary"))
        #expect(md.contains("## TL;DR"))
    }

    @Test func markdownEmbedsActionItemChecklist() {
        let md = MarkdownRenderer.render(
            summary: sampleSummary(),
            transcript: sampleTranscript(),
            metadata: sampleMetadata(),
            includeTranscript: false
        )
        // The Action Items section delegates to ActionItemsRenderer.
        #expect(md.contains("- [ ] @alice"), "Action item checkbox missing in:\n\(md)")
    }

    @Test func markdownIncludesTranscriptOnlyWhenRequested() {
        let metadata = sampleMetadata()
        let transcript = sampleTranscript()

        let without = MarkdownRenderer.render(
            summary: sampleSummary(),
            transcript: transcript,
            metadata: metadata,
            includeTranscript: false
        )
        #expect(!without.contains("## Transcript"))

        let with = MarkdownRenderer.render(
            summary: sampleSummary(),
            transcript: transcript,
            metadata: metadata,
            includeTranscript: true
        )
        #expect(with.contains("## Transcript"))
        // Resolved speaker name is used, not the raw id.
        #expect(with.contains("**Alice**"))
        #expect(!with.contains("speaker_0"))
    }

    @Test func markdownWithNilSummaryOmitsSummarySections() {
        let md = MarkdownRenderer.render(
            summary: nil,
            transcript: sampleTranscript(),
            metadata: sampleMetadata(),
            includeTranscript: true
        )
        #expect(!md.contains("## TL;DR"))
        #expect(!md.contains("## Summary"))
        // Header + transcript still render.
        #expect(md.contains("# Launch Planning"))
        #expect(md.contains("## Transcript"))
    }

    // MARK: - ActionItemsRenderer

    @Test func actionItemsRendererFormatsCheckboxOwnerAndTask() {
        let rendered = ActionItemsRenderer.render(sampleSummary())
        let lines = rendered.split(separator: "\n").map(String.init)

        #expect(lines.count == 2)
        // Each line begins with the unchecked box + @owner.
        #expect(lines[0].hasPrefix("- [ ] @alice"), "Got: \(lines[0])")
        #expect(lines[0].contains("Finalize the changelog"))
        // Due date is appended when present.
        #expect(lines[0].contains("2026-06-05"))

        #expect(lines[1].hasPrefix("- [ ] @bob"), "Got: \(lines[1])")
        // No due date -> no "(due:" suffix.
        #expect(!lines[1].contains("(due:"))
    }

    @Test func actionItemsRendererEmptyShowsPlaceholderCheckbox() {
        let empty = MeetingSummary(tldr: "x")
        let rendered = ActionItemsRenderer.render(empty)
        #expect(rendered.hasPrefix("- [ ]"))
    }

}
