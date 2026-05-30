import Testing
@testable import KleothCore

@Suite struct NormalizerTests {
    // MARK: - Single-channel: words -> grouped speaker turns

    @Test func singleChannelGroupsConsecutiveWordsIntoSpeakerTurns() throws {
        let response = try Fixtures.scribeResponse("scribe_words")
        let transcript = TranscriptNormalizer.normalize(response)

        // Two speakers -> two grouped utterances, in speaking order.
        #expect(transcript.utterances.count == 2)

        let first = transcript.utterances[0]
        #expect(first.speakerId == "speaker_0")
        // Spacing/punctuation tokens are dropped; word texts are space-joined.
        #expect(first.text == "Hi everyone")
        #expect(first.start == 0.0)
        #expect(first.end == 0.9)

        let second = transcript.utterances[1]
        #expect(second.speakerId == "speaker_1")
        #expect(second.text == "Hello glad to be here")
        #expect(second.start == 1.2)
        #expect(second.end == 2.7)
    }

    @Test func singleChannelCarriesLanguageAndDuration() throws {
        let response = try Fixtures.scribeResponse("scribe_words")
        let transcript = TranscriptNormalizer.normalize(response)

        #expect(transcript.languageCode == "en")
        #expect(transcript.durationSecs == 2.75)
    }

    @Test func singleChannelBreaksOnSilenceGap() {
        // Same speaker, but a > maxGap (1.5s) silence between the two words
        // must split them into separate utterances.
        let words = [
            ScribeWord(text: "Alpha", start: 0.0, end: 0.5, type: "word", speakerId: "speaker_0"),
            ScribeWord(text: "Beta", start: 5.0, end: 5.5, type: "word", speakerId: "speaker_0"),
        ]
        let transcript = TranscriptNormalizer.normalize(ScribeResponse(words: words))

        #expect(transcript.utterances.count == 2)
        #expect(transcript.utterances[0].text == "Alpha")
        #expect(transcript.utterances[1].text == "Beta")
        #expect(transcript.utterances.map(\.speakerId) == ["speaker_0", "speaker_0"])
    }

    @Test func singleChannelMissingSpeakerDefaultsToSpeakerZero() {
        let words = [
            ScribeWord(text: "Hello", start: 0.0, end: 0.4, type: "word", speakerId: nil),
            ScribeWord(text: "world", start: 0.4, end: 0.8, type: "word", speakerId: nil),
        ]
        let transcript = TranscriptNormalizer.normalize(ScribeResponse(words: words))

        #expect(transcript.utterances.count == 1)
        #expect(transcript.utterances[0].speakerId == "speaker_0")
        #expect(transcript.utterances[0].text == "Hello world")
    }

    // MARK: - Multi-channel: transcripts -> per-channel utterances sorted by start

    @Test func multiChannelProducesPerChannelUtterancesSortedByStart() throws {
        let response = try Fixtures.scribeResponse("scribe_multichannel")
        let transcript = TranscriptNormalizer.normalize(response)

        #expect(transcript.utterances.count == 2)

        // Sorted by start: channel 0 (0.0) precedes channel 1 (1.2).
        let starts = transcript.utterances.compactMap(\.start)
        #expect(starts == starts.sorted())

        #expect(transcript.utterances[0].speakerId == "speaker_0")
        #expect(transcript.utterances[0].text == "Hi everyone")
        #expect(transcript.utterances[0].start == 0.0)

        #expect(transcript.utterances[1].speakerId == "speaker_1")
        #expect(transcript.utterances[1].text == "Hello glad to be here")
        #expect(transcript.utterances[1].start == 1.2)
    }

    @Test func multiChannelSortIsByStartNotChannelOrder() {
        // Channel listed second actually starts first; output must reorder so
        // the earlier-starting utterance comes first.
        let channels = [
            ScribeChannelTranscript(
                words: [ScribeWord(text: "Later", start: 10.0, end: 10.5, type: "word")],
                channelIndex: 0
            ),
            ScribeChannelTranscript(
                words: [ScribeWord(text: "Earlier", start: 1.0, end: 1.5, type: "word")],
                channelIndex: 1
            ),
        ]
        let transcript = TranscriptNormalizer.normalize(ScribeResponse(transcripts: channels))

        #expect(transcript.utterances.count == 2)
        #expect(transcript.utterances[0].text == "Earlier")
        #expect(transcript.utterances[0].speakerId == "speaker_1")
        #expect(transcript.utterances[1].text == "Later")
        #expect(transcript.utterances[1].speakerId == "speaker_0")
    }

    @Test func multiChannelDerivesSpeakerFromChannelIndex() {
        let channels = [
            ScribeChannelTranscript(
                words: [ScribeWord(text: "Zero", start: 0.0, end: 0.2, type: "word")],
                channelIndex: 0
            ),
            ScribeChannelTranscript(
                words: [ScribeWord(text: "Three", start: 0.5, end: 0.7, type: "word")],
                channelIndex: 3
            ),
        ]
        let transcript = TranscriptNormalizer.normalize(ScribeResponse(transcripts: channels))

        let bySpeaker = Dictionary(
            uniqueKeysWithValues: transcript.utterances.map { ($0.speakerId, $0.text) }
        )
        #expect(bySpeaker["speaker_0"] == "Zero")
        #expect(bySpeaker["speaker_3"] == "Three")
    }
}
