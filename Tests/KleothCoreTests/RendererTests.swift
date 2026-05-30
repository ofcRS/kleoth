import Testing
@testable import KleothCore

@Suite struct RendererTests {
    // MARK: - Fixtures

    private func sampleSummary() -> MeetingSummary {
        MeetingSummary(
            tldr: "We shipped the beta and picked a launch date.",
            decisions: ["Launch on June 10", "Use the blue theme"],
            actionItems: [
                ActionItem(owner: "alice", task: "Finalize the changelog", due: "2026-06-05"),
                ActionItem(owner: "bob", task: "Email the beta list", due: nil),
            ],
            keyPoints: ["Beta feedback was positive", "Perf regressions resolved"],
            perSpeakerHighlights: [
                SpeakerHighlight(speaker: "Alice", highlights: ["Owns the changelog"]),
            ],
            openQuestions: ["Do we need a press release?"],
            suggestedTags: ["launch", "beta release"]
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
        #expect(md.contains("## Decisions"), "Missing Decisions header in:\n\(md)")
        #expect(md.contains("## Action Items"), "Missing Action Items header in:\n\(md)")
        // Other sections that should also be present.
        #expect(md.contains("## Key Points"))
        #expect(md.contains("## Open Questions"))
        // Title header.
        #expect(md.contains("# Launch Planning"))
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
        #expect(!md.contains("## Decisions"))
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
        let empty = MeetingSummary(
            tldr: "x", decisions: [], actionItems: [], keyPoints: [],
            perSpeakerHighlights: [], openQuestions: [], suggestedTags: []
        )
        let rendered = ActionItemsRenderer.render(empty)
        #expect(rendered.hasPrefix("- [ ]"))
    }

    // MARK: - SlackRenderer

    @Test func slackOutputUsesBoldMrkdwnHeaders() {
        let slack = SlackRenderer.render(summary: sampleSummary(), metadata: sampleMetadata())

        // Slack mrkdwn bold is single asterisks.
        #expect(slack.contains("*Launch Planning*"), "Missing bold title in:\n\(slack)")
        #expect(slack.contains("*TL;DR*"), "Missing bold TL;DR in:\n\(slack)")
        #expect(slack.contains("*Decisions*"))
        #expect(slack.contains("*Action items*"))
        // Slack must not emit Markdown ATX headers.
        #expect(!slack.contains("## "))
    }

    @Test func slackActionItemsUseBulletAndOwner() {
        let slack = SlackRenderer.render(summary: sampleSummary(), metadata: sampleMetadata())
        #expect(slack.contains("• @alice"), "Missing Slack bullet action item in:\n\(slack)")
    }
}
