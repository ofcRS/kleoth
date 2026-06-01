import Testing
@testable import KleothCore

@Suite struct ChannelAttributionTests {
    // Channel 0 is loud over hops [0,1,2]; channel 1 is loud over hops [3,4,5].
    private let ch0: [Float] = [1, 1, 1, 0, 0, 0]
    private let ch1: [Float] = [0, 0, 0, 1, 1, 1]

    @Test func wordInChannel0SpanGetsSpeaker0() {
        let words = [ScribeWord(text: "A", start: 0, end: 1, type: "word")]
        let result = ChannelAttribution.assignSpeakers(
            words: words, channel0Energy: ch0, channel1Energy: ch1, hopSeconds: 1.0
        )
        #expect(result[0].speakerId == "speaker_0")
    }

    @Test func wordInChannel1SpanGetsSpeaker1() {
        let words = [ScribeWord(text: "B", start: 3, end: 4, type: "word")]
        let result = ChannelAttribution.assignSpeakers(
            words: words, channel0Energy: ch0, channel1Energy: ch1, hopSeconds: 1.0
        )
        #expect(result[0].speakerId == "speaker_1")
    }

    @Test func mixedSequenceAttributesEachWordToItsLouderChannel() {
        let words = [
            ScribeWord(text: "A", start: 0, end: 1, type: "word"),
            ScribeWord(text: "B", start: 3, end: 4, type: "word"),
        ]
        let result = ChannelAttribution.assignSpeakers(
            words: words, channel0Energy: ch0, channel1Energy: ch1, hopSeconds: 1.0
        )
        #expect(result.map(\.speakerId) == ["speaker_0", "speaker_1"])
        // Text and other fields are preserved.
        #expect(result.map(\.text) == ["A", "B"])
    }

    @Test func tieGoesToSpeaker0() {
        // Equal energy on both channels over the span -> speaker_0 wins.
        let words = [ScribeWord(text: "tie", start: 0, end: 1, type: "word")]
        let result = ChannelAttribution.assignSpeakers(
            words: words,
            channel0Energy: [1, 1],
            channel1Energy: [1, 1],
            hopSeconds: 1.0
        )
        #expect(result[0].speakerId == "speaker_0")
    }

    @Test func nilTimestampWordCarriesPreviousAssignment() {
        let words = [
            ScribeWord(text: "B", start: 3, end: 4, type: "word"), // -> speaker_1
            ScribeWord(text: "carryover", start: nil, end: nil, type: "word"),
        ]
        let result = ChannelAttribution.assignSpeakers(
            words: words, channel0Energy: ch0, channel1Energy: ch1, hopSeconds: 1.0
        )
        #expect(result[0].speakerId == "speaker_1")
        // No timestamps -> inherit the previous word's speaker.
        #expect(result[1].speakerId == "speaker_1")
    }

    @Test func firstWordWithNilTimestampDefaultsToSpeaker0() {
        let words = [ScribeWord(text: "first", start: nil, end: nil, type: "word")]
        let result = ChannelAttribution.assignSpeakers(
            words: words, channel0Energy: ch0, channel1Energy: ch1, hopSeconds: 1.0
        )
        #expect(result[0].speakerId == "speaker_0")
    }

    @Test func bothChannelsSilentCarriesPreviousAssignment() {
        // Word B lands in channel-1's loud region; word C lands in a silent
        // region (hops [6,7] are zero) and must inherit speaker_1.
        let ch0 = [Float](repeating: 0, count: 8)
        var ch1 = ch0
        ch1[3] = 1; ch1[4] = 1 // channel 1 loud only over hops 3..4
        let words = [
            ScribeWord(text: "B", start: 3, end: 4, type: "word"),
            ScribeWord(text: "C", start: 6, end: 7, type: "word"),
        ]
        let result = ChannelAttribution.assignSpeakers(
            words: words, channel0Energy: ch0, channel1Energy: ch1, hopSeconds: 1.0
        )
        #expect(result[0].speakerId == "speaker_1")
        #expect(result[1].speakerId == "speaker_1")
    }

    @Test func customSpeakerIdsAreUsed() {
        let words = [
            ScribeWord(text: "A", start: 0, end: 1, type: "word"),
            ScribeWord(text: "B", start: 3, end: 4, type: "word"),
        ]
        let result = ChannelAttribution.assignSpeakers(
            words: words,
            channel0Energy: ch0,
            channel1Energy: ch1,
            hopSeconds: 1.0,
            speaker0Id: "you",
            speaker1Id: "them"
        )
        #expect(result.map(\.speakerId) == ["you", "them"])
    }
}
