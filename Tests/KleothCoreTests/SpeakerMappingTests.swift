import Testing
@testable import KleothCore

@Suite struct SpeakerMappingTests {
    private func transcript() -> Transcript {
        Transcript(
            utterances: [
                Utterance(speakerId: "speaker_0", start: 0.0, end: 1.0, text: "First from zero"),
                Utterance(speakerId: "speaker_1", start: 1.5, end: 2.0, text: "First from one"),
                Utterance(speakerId: "speaker_0", start: 2.5, end: 3.0, text: "Second from zero"),
                Utterance(speakerId: "speaker_0", start: 3.5, end: 4.0, text: "Third from zero"),
                Utterance(speakerId: "speaker_0", start: 4.5, end: 5.0, text: "Fourth from zero"),
                Utterance(speakerId: "speaker_1", start: 5.5, end: 6.0, text: "Second from one"),
            ],
            languageCode: "en",
            durationSecs: 6.0
        )
    }

    // MARK: - apply

    @Test func applySetsSpeakerNamesFromMap() {
        let map = SpeakerMap(names: ["speaker_0": "Alice", "speaker_1": "Bob"])
        let result = SpeakerMapper.apply(map, to: transcript())

        #expect(result.utterances.count == 6)
        for utterance in result.utterances {
            switch utterance.speakerId {
            case "speaker_0": #expect(utterance.speakerName == "Alice")
            case "speaker_1": #expect(utterance.speakerName == "Bob")
            default: Issue.record("Unexpected speaker \(utterance.speakerId)")
            }
        }
        // Non-name fields are preserved.
        #expect(result.durationSecs == 6.0)
        #expect(result.languageCode == "en")
    }

    @Test func applyLeavesUnmappedSpeakersNil() {
        let map = SpeakerMap(names: ["speaker_0": "Alice"]) // speaker_1 unmapped
        let result = SpeakerMapper.apply(map, to: transcript())

        let oneNames = result.utterances
            .filter { $0.speakerId == "speaker_1" }
            .map(\.speakerName)
        #expect(oneNames == [nil, nil])
    }

    @Test func applyWithEmptyMapClearsNames() {
        // Start from a transcript that already has a name, then apply an empty map.
        var t = transcript()
        t.utterances[0].speakerName = "Stale"
        let result = SpeakerMapper.apply(SpeakerMap(), to: t)
        #expect(result.utterances[0].speakerName == nil)
    }

    // MARK: - apply(toSummary:) — the rename must reach summary name fields

    /// A summary whose owners/highlight speakers were written against the
    /// default "You"/"Them" names (plus a bare id and an unrelated owner).
    private func summary() -> MeetingSummary {
        MeetingSummary(
            tldr: "t",
            overview: "You said things to Them.",
            actionItems: [
                ActionItem(owner: "You", task: "Send the dataset"),
                ActionItem(owner: "speaker_1", task: "Review the PR"),
                ActionItem(owner: "unassigned", task: "Book a room"),
            ],
            perSpeakerHighlights: [
                SpeakerHighlight(speaker: "You", highlights: ["Asked for the dataset"]),
                SpeakerHighlight(speaker: "Them", highlights: ["Promised the PR"]),
            ]
        )
    }

    /// The pre-rename transcript carrying the previous display names — the
    /// old→new link the summary remap relies on.
    private func namedTranscript() -> Transcript {
        SpeakerMapper.apply(
            SpeakerMap(names: ["speaker_0": "You", "speaker_1": "Them"]),
            to: transcript()
        )
    }

    @Test func applyToSummaryRenamesOwnersAndHighlightSpeakers() {
        let map = SpeakerMap(names: ["speaker_0": "Alice", "speaker_1": "Bob"])
        let result = SpeakerMapper.apply(map, toSummary: summary(), previousTranscript: namedTranscript())

        // Previous display names follow the rename…
        #expect(result.actionItems[0].owner == "Alice")
        #expect(result.perSpeakerHighlights[0].speaker == "Alice")
        #expect(result.perSpeakerHighlights[1].speaker == "Bob")
        // …and so does a summary that referenced the bare id.
        #expect(result.actionItems[1].owner == "Bob")
        // Non-speaker owners and free prose are untouched.
        #expect(result.actionItems[2].owner == "unassigned")
        #expect(result.overview == "You said things to Them.")
        // Tasks are never rewritten.
        #expect(result.actionItems[0].task == "Send the dataset")
    }

    /// Renaming a second time keeps working: the previous transcript now carries
    /// the first rename's names, which is exactly what the saved summary holds.
    @Test func applyToSummaryChainsAcrossConsecutiveRenames() {
        let first = SpeakerMap(names: ["speaker_0": "Alice", "speaker_1": "Bob"])
        let renamedSummary = SpeakerMapper.apply(first, toSummary: summary(), previousTranscript: namedTranscript())
        let renamedTranscript = SpeakerMapper.apply(first, to: transcript())

        let second = SpeakerMap(names: ["speaker_0": "Алексей", "speaker_1": "Bob"])
        let result = SpeakerMapper.apply(second, toSummary: renamedSummary, previousTranscript: renamedTranscript)

        #expect(result.actionItems[0].owner == "Алексей")
        #expect(result.perSpeakerHighlights[0].speaker == "Алексей")
        #expect(result.perSpeakerHighlights[1].speaker == "Bob")
    }

    /// Ids absent from the map keep their existing summary names.
    @Test func applyToSummaryLeavesUnmappedSpeakersAlone() {
        let map = SpeakerMap(names: ["speaker_0": "Alice"]) // speaker_1 unmapped
        let result = SpeakerMapper.apply(map, toSummary: summary(), previousTranscript: namedTranscript())

        #expect(result.actionItems[0].owner == "Alice")
        #expect(result.perSpeakerHighlights[1].speaker == "Them")
    }

    // MARK: - samples

    @Test func samplesReturnsFirstNPerSpeakerInTranscriptOrder() {
        let samples = SpeakerMapper.samples(from: transcript(), perSpeaker: 3)

        // speaker_0 has four utterances; only the first three are sampled.
        #expect(samples["speaker_0"] == [
            "First from zero",
            "Second from zero",
            "Third from zero",
        ])
        // speaker_1 has two utterances; both are returned (fewer than N).
        #expect(samples["speaker_1"] == [
            "First from one",
            "Second from one",
        ])
    }

    @Test func samplesDefaultPerSpeakerIsThree() {
        let samples = SpeakerMapper.samples(from: transcript())
        #expect(samples["speaker_0"]?.count == 3)
    }

    @Test func samplesWithLargerNReturnsAllAvailable() {
        let samples = SpeakerMapper.samples(from: transcript(), perSpeaker: 10)
        #expect(samples["speaker_0"]?.count == 4)
        #expect(samples["speaker_1"]?.count == 2)
    }

    @Test func samplesWithNonPositiveNReturnsEmptyListsForEachSpeaker() {
        let samples = SpeakerMapper.samples(from: transcript(), perSpeaker: 0)
        // Both speakers appear as keys, each with an empty sample list.
        #expect(Set(samples.keys) == ["speaker_0", "speaker_1"])
        #expect(samples["speaker_0"] == [])
        #expect(samples["speaker_1"] == [])
    }
}
