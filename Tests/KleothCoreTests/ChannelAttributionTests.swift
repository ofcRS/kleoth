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

    // MARK: - mapDiarizedSpeakers (Scribe clusters → You/Them by per-cluster energy)

    /// Every word in a Scribe diarization cluster gets ONE label, taken from the
    /// cluster's dominant channel — a single word landing in the other channel's
    /// loud region must NOT flip. This is the per-word split this method replaces.
    @Test func diarizedClusterIsLabeledAsOneSpeaker() {
        let ch0: [Float] = [10, 10, 10, 10, 0, 0]
        let ch1: [Float] = [0, 0, 0, 0, 10, 10]
        let words = [
            ScribeWord(text: "you1", start: 0, end: 2, type: "word", speakerId: "A"),
            ScribeWord(text: "you2", start: 5, end: 5, type: "word", speakerId: "A"), // in ch1's loud hop
            ScribeWord(text: "them1", start: 4, end: 5, type: "word", speakerId: "B"),
        ]
        let result = ChannelAttribution.mapDiarizedSpeakers(
            words: words, channel0Energy: ch0, channel1Energy: ch1, hopSeconds: 1.0
        )
        let byText = Dictionary(uniqueKeysWithValues: result.map { ($0.text, $0.speakerId) })
        #expect(byText["you1"] == "speaker_0")
        #expect(byText["you2"] == "speaker_0") // cluster wins; NOT flipped to speaker_1
        #expect(byText["them1"] == "speaker_1")
        #expect(result.map(\.text) == ["you1", "you2", "them1"]) // order & text preserved
    }

    /// When the mic channel bleeds (both clusters louder on ch0 in absolute
    /// terms), the two clusters are still separated by RELATIVE affinity, so You
    /// and Them never collapse onto the same speaker.
    @Test func diarizedClustersStaySeparateUnderChannelBleed() {
        let ch0: [Float] = [10, 10, 10, 10, 10, 10] // mic loud everywhere (bleed)
        let ch1: [Float] = [0, 0, 0, 8, 8, 8]        // system weaker, only later
        let words = [
            ScribeWord(text: "you", start: 0, end: 1, type: "word", speakerId: "A"),
            ScribeWord(text: "them", start: 3, end: 4, type: "word", speakerId: "B"),
        ]
        let result = ChannelAttribution.mapDiarizedSpeakers(
            words: words, channel0Energy: ch0, channel1Energy: ch1, hopSeconds: 1.0
        )
        let byText = Dictionary(uniqueKeysWithValues: result.map { ($0.text, $0.speakerId) })
        #expect(byText["you"] == "speaker_0")
        #expect(byText["them"] == "speaker_1") // not collapsed onto speaker_0
    }
}
