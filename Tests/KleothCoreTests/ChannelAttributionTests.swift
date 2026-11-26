import Foundation
import Testing
@testable import KleothCore

/// Per-word You/Them attribution from the two lanes' energy, on synthetic
/// envelopes (50 ms hops, levels in dB). The mic is You, the system lane Them.
@Suite struct ChannelAttributionTests {
    private static let you = "speaker_0"
    private static let them = "speaker_1"

    /// Synthetic lanes at 50 ms hops, built in dB: a slightly uneven floor, and
    /// speech as a syllable pattern (0–10.5 dB under a level) of its own for
    /// each voice, as two different people's speech never moves together.
    struct Lanes {
        static let hop = 0.05
        var mic: [Float]
        var system: [Float]

        init(seconds: Double, micFloor: Float = -68, systemFloor: Float = -90) {
            let count = Int((seconds / Self.hop).rounded())
            mic = (0..<count).map { micFloor + Float($0 % 3) * 0.5 - 0.5 }
            system = (0..<count).map { systemFloor + Float($0 % 3) * 0.5 - 0.5 }
        }

        static func hops(_ from: Double, _ to: Double, count: Int) -> Range<Int> {
            let lower = max(0, Int((from / hop).rounded()))
            let upper = min(count, Int((to / hop).rounded()))
            return lower..<max(lower, upper)
        }

        static func syllable(_ hop: Int, voice: UInt32) -> Float {
            let mixed = (UInt32(truncatingIfNeeded: hop) &* 2_654_435_761) ^ (voice &* 40_503 &+ 0x9e37)
            return Float((mixed &* 2_246_822_519) >> 29) * 1.5
        }

        mutating func micSpeech(_ from: Double, _ to: Double, at level: Float = -22, voice: UInt32 = 1) {
            for i in Self.hops(from, to, count: mic.count) {
                mic[i] = max(mic[i], level - Self.syllable(i, voice: voice))
            }
        }

        mutating func systemSpeech(_ from: Double, _ to: Double, at level: Float = -18, voice: UInt32 = 2) {
            for i in Self.hops(from, to, count: system.count) {
                system[i] = max(system[i], level - Self.syllable(i, voice: voice))
            }
        }

        /// Speakers in the room: the mic hears the system lane `gain` dB down,
        /// `lag` seconds later (positive: the mic lane runs behind).
        mutating func bleedSystemIntoMic(gain: Float, lag: Double) {
            let shift = Int((lag / Self.hop).rounded())
            let source = system
            for j in mic.indices {
                let i = j - shift
                guard i >= 0, i < source.count else { continue }
                mic[j] = max(mic[j], source[i] + gain)
            }
        }

        var micEnergy: [Float] { mic.map { powf(10, $0 / 20) } }
        var systemEnergy: [Float] { system.map { powf(10, $0 / 20) } }
    }

    /// Deterministic speech bursts between `from` and `to`: lengths 1–5 s,
    /// pauses 0.6–2.4 s, so the lanes have a pattern to line up by.
    static func bursts(_ from: Double, _ to: Double) -> [(Double, Double)] {
        var result: [(Double, Double)] = []
        var t = from
        var state: UInt32 = 12345
        func next() -> Double {
            state = state &* 1_103_515_245 &+ 12345
            return Double((state >> 16) & 0x7fff) / 32767
        }
        while t < to {
            let length = 1 + 4 * next()
            let end = min(to, t + length)
            result.append((t, end))
            t = end + 0.6 + 1.8 * next()
        }
        return result
    }

    /// Words of 0.25 s with 0.05 s gaps filling `[from, to)`, in one Scribe cluster.
    static func words(_ cluster: String?, _ from: Double, _ to: Double, length: Double = 0.25, gap: Double = 0.05) -> [ScribeWord] {
        var result: [ScribeWord] = []
        var t = from
        var index = 0
        while t + length <= to + 1e-9 {
            result.append(ScribeWord(
                text: "\(cluster ?? "none")\(index)", start: t, end: t + length, type: "word", speakerId: cluster))
            t += length + gap
            index += 1
        }
        return result
    }

    static func attribute(_ words: [ScribeWord], _ lanes: Lanes) -> [ScribeWord] {
        ChannelAttribution.attribute(
            words: words, micEnergy: lanes.micEnergy, systemEnergy: lanes.systemEnergy, hopSeconds: Lanes.hop
        ).words
    }

    static func labels(_ words: [ScribeWord], cluster: String) -> Set<String?> {
        Set(words.filter { $0.diarizedSpeakerId == cluster }.map(\.speakerId))
    }

    // MARK: - The reported bug

    /// The mic carries nothing but its floor for the whole meeting; Scribe hears
    /// two remote voices, one much quieter on the system lane (so it "leans" to
    /// the mic by raw loudness). Nobody is You.
    @Test func silentMicYieldsNoWordsForYou() {
        var lanes = Lanes(seconds: 60)
        lanes.systemSpeech(2, 20, at: -14)
        lanes.systemSpeech(22, 40, at: -36)
        lanes.systemSpeech(42, 58, at: -14)
        let words = Self.words("A", 2, 20) + Self.words("B", 22, 40) + Self.words("A", 42, 58)

        let result = Self.attribute(words, lanes)
        #expect(result.filter { $0.speakerId == Self.you }.isEmpty)
        #expect(result.count == words.count)
    }

    /// Laptop speakers: the mic hears every remote word 9 dB down, louder than
    /// the user's own voice would be. With the user silent, nothing is You.
    @Test func speakerBleedAloneIsNotTheUser() {
        var lanes = Lanes(seconds: 150, micFloor: -71, systemFloor: -99)
        let remote = Self.bursts(0, 140)
        var words: [ScribeWord] = []
        for (index, (from, to)) in remote.enumerated() {
            let voice = index % 2 == 0 ? "A" : "B"
            lanes.systemSpeech(from, to, at: voice == "A" ? -18 : -24, voice: voice == "A" ? 2 : 3)
            words += Self.words(voice, from, to)
        }
        lanes.bleedSystemIntoMic(gain: -9, lag: 0.05)

        let result = Self.attribute(words, lanes)
        #expect(result.filter { $0.speakerId == Self.you }.isEmpty)
    }

    /// The same speakers with the user taking a turn of their own, quieter on
    /// the mic than the bleed: the turn is You, the remote voices stay Them.
    @Test func speakerBleedKeepsTheUsersOwnTurn() {
        var lanes = Lanes(seconds: 170, micFloor: -71, systemFloor: -99)
        var words: [ScribeWord] = []
        for (index, (from, to)) in Self.bursts(0, 140).enumerated() {
            let voice = index % 2 == 0 ? "A" : "B"
            lanes.systemSpeech(from, to, at: voice == "A" ? -18 : -24, voice: voice == "A" ? 2 : 3)
            words += Self.words(voice, from, to)
        }
        lanes.bleedSystemIntoMic(gain: -9, lag: 0.05)
        lanes.micSpeech(145, 160, at: -40)
        words += Self.words("U", 145, 160)

        let result = Self.attribute(words, lanes)
        #expect(Self.labels(result, cluster: "U") == [Self.you])
        #expect(Self.labels(result, cluster: "A") == [Self.them])
        #expect(Self.labels(result, cluster: "B") == [Self.them])
    }

    /// The lanes drift apart: the mic hears the speakers six seconds behind the
    /// system lane. Scribe transcribes the echo after the remote stops (mic-only
    /// sound at that moment): still the remote. The user's later turn is You.
    @Test func bleedSecondsBehindTheSystemLaneIsStillBleed() {
        var lanes = Lanes(seconds: 200)
        var words: [ScribeWord] = []
        for (from, to) in Self.bursts(0, 150) {
            lanes.systemSpeech(from, to)
            words += Self.words("A", from, to)
        }
        lanes.bleedSystemIntoMic(gain: -10, lag: 6)
        words += Self.words("E", 150.5, 155.5)  // the echo of the last burst, mic only
        lanes.micSpeech(170, 180, at: -30)
        words += Self.words("U", 170, 180)

        let result = Self.attribute(words, lanes)
        #expect(Self.labels(result, cluster: "E") == [Self.them])
        #expect(Self.labels(result, cluster: "U") == [Self.you])
        #expect(Self.labels(result, cluster: "A") == [Self.them])
    }

    /// The other way round: the system lane carries the user's own voice
    /// (a call app playing the mic back) 0.15 s late, as loud as the remote.
    /// The user's words have both lanes loud, and are still You.
    @Test func theUsersVoicePlayedBackOnTheSystemLaneIsStillTheUser() {
        var lanes = Lanes(seconds: 220)
        var words: [ScribeWord] = []
        for (index, (from, to)) in Self.bursts(0, 210).enumerated() {
            if index % 3 == 1 {
                lanes.micSpeech(from, to, at: -20)
                words += Self.words("U", from, to)
            } else {
                lanes.systemSpeech(from, to)
                words += Self.words("R", from, to)
            }
        }
        let shift = 3  // hops: the system lane hears the mic 0.15 s later, at 0 dB
        let mic = lanes.mic
        for i in lanes.system.indices where i >= shift {
            lanes.system[i] = max(lanes.system[i], mic[i - shift] + 2)
        }

        let attribution = ChannelAttribution.attribute(
            words: words, micEnergy: lanes.micEnergy, systemEnergy: lanes.systemEnergy, hopSeconds: Lanes.hop)
        #expect(attribution.systemHearsMicSeconds > 0)
        #expect(attribution.micHearsSystemSeconds == 0)
        #expect(Self.labels(attribution.words, cluster: "U") == [Self.you])
        #expect(Self.labels(attribution.words, cluster: "R") == [Self.them])
    }

    /// Scribe put the user and a remote speaker in one cluster: the words split
    /// by lane, one turn each.
    @Test func oneClusterHoldingTwoPeopleOnDifferentLanesIsSplit() {
        var lanes = Lanes(seconds: 30)
        lanes.micSpeech(2, 8)
        lanes.systemSpeech(9, 15)
        lanes.systemSpeech(17, 25, at: -20)
        let first = Self.words("A", 2, 8)
        let second = Self.words("A", 9, 15)
        let words = first + second + Self.words("B", 17, 25)

        let result = Self.attribute(words, lanes)
        #expect(Set(result.prefix(first.count).map(\.speakerId)) == [Self.you])
        #expect(Set(result.dropFirst(first.count).prefix(second.count).map(\.speakerId)) == [Self.them])
        #expect(Self.labels(result, cluster: "B") == [Self.them])
    }

    // MARK: - Smoothing and the Scribe prior

    /// A word in the middle of a remote sentence, with a mic blip and a dip on
    /// the system lane under it, stays with its sentence.
    @Test func aWordInsideASentenceDoesNotFlip() {
        var lanes = Lanes(seconds: 20)
        lanes.micSpeech(2, 6)  // the same cluster also holds a mic turn: no prior either way
        lanes.systemSpeech(10, 14)
        let sentence = Self.words("A", 10, 14)
        let odd = sentence[6]
        for i in Lanes.hops(odd.start! - 0.05, odd.end! + 0.05, count: lanes.system.count) {
            lanes.system[i] = -90
            lanes.mic[i] = -25
        }
        let words = Self.words("A", 2, 6) + sentence

        let result = Self.attribute(words, lanes)
        #expect(Set(result.prefix(Self.words("A", 2, 6).count).map(\.speakerId)) == [Self.you])
        #expect(Set(result.suffix(sentence.count).map(\.speakerId)) == [Self.them])
    }

    /// Words with no sound under them on either lane follow their cluster.
    @Test func wordsWithoutLaneEvidenceFollowTheirCluster() {
        var lanes = Lanes(seconds: 50)
        lanes.micSpeech(2, 10)
        lanes.systemSpeech(12, 20)
        let words = Self.words("U", 2, 10) + Self.words("R", 12, 20)
            + [ScribeWord(text: "quiet", start: 30, end: 30.3, type: "word", speakerId: "U"),
               ScribeWord(text: "hush", start: 40, end: 40.3, type: "word", speakerId: "R")]

        let result = Self.attribute(words, lanes)
        #expect(result[result.count - 2].speakerId == Self.you)
        #expect(result[result.count - 1].speakerId == Self.them)
    }

    /// A word without timestamps follows its neighbours.
    @Test func wordsWithoutTimestampsFollowTheirNeighbours() {
        var lanes = Lanes(seconds: 20)
        lanes.micSpeech(2, 6)
        lanes.systemSpeech(8, 12)
        let words = Self.words("U", 2, 6)
            + [ScribeWord(text: "untimed", type: "word", speakerId: "U")]
            + Self.words("R", 8, 12)

        let result = Self.attribute(words, lanes)
        #expect(result[Self.words("U", 2, 6).count].speakerId == Self.you)
    }

    /// The remote's line is still open (faint, but above its floor) while the
    /// user talks far above theirs: the mic clearly dominates.
    @Test func aClearlyDominantMicIsYouOverAFaintSystemLane() {
        var lanes = Lanes(seconds: 40)
        lanes.systemSpeech(0, 20)
        lanes.systemSpeech(20, 30, at: -40)
        lanes.micSpeech(20, 30, at: -20)
        let words = Self.words("R", 0, 20) + Self.words("U", 20, 30)

        let result = Self.attribute(words, lanes)
        #expect(Self.labels(result, cluster: "U") == [Self.you])
        #expect(Self.labels(result, cluster: "R") == [Self.them])
    }

    /// Two people at one mic (an in-room meeting), nothing on the system lane:
    /// lanes can't tell them apart, so Scribe's split stands; the voice with
    /// the most words on the mic is You.
    @Test func twoVoicesSharingTheMicKeepScribesSplit() {
        var lanes = Lanes(seconds: 240)
        var words: [ScribeWord] = []
        for (index, (from, to)) in Self.bursts(0, 230).enumerated() {
            let voice = index % 3 == 2 ? "Q" : "P"
            lanes.micSpeech(from, to, at: voice == "P" ? -22 : -26, voice: voice == "P" ? 1 : 4)
            words += Self.words(voice, from, to)
        }

        let result = Self.attribute(words, lanes)
        #expect(Self.labels(result, cluster: "P") == [Self.you])
        #expect(Self.labels(result, cluster: "Q") == [Self.them])
    }

    // MARK: - Lanes that are missing, short or unreadable

    /// A header-only or missing `mic.m4a` gives an empty envelope: nothing in
    /// the mix came from the mic.
    @Test func anAbsentMicMeansEveryWordIsThem() {
        var lanes = Lanes(seconds: 20)
        lanes.systemSpeech(2, 18)
        let words = Self.words("A", 2, 10) + Self.words("B", 10, 18)
        let result = ChannelAttribution.attribute(
            words: words, micEnergy: [], systemEnergy: lanes.systemEnergy, hopSeconds: Lanes.hop
        ).words
        #expect(Set(result.map(\.speakerId)) == [Self.them])
    }

    /// No system lane: every sound in the mix came from the mic.
    @Test func anAbsentSystemLaneMeansEveryWordIsYou() {
        var lanes = Lanes(seconds: 20)
        lanes.micSpeech(2, 18)
        let words = Self.words("A", 2, 10) + Self.words("B", 10, 18)
        let result = ChannelAttribution.attribute(
            words: words, micEnergy: lanes.micEnergy, systemEnergy: [], hopSeconds: Lanes.hop
        ).words
        #expect(Set(result.map(\.speakerId)) == [Self.you])
    }

    /// The mic lane stopped early (a failed capture): past its end it is silent.
    @Test func aMicLaneThatEndsEarlyIsSilentPastItsEnd() {
        var lanes = Lanes(seconds: 30)
        lanes.micSpeech(2, 6)
        lanes.systemSpeech(14, 28)
        var mic = lanes.micEnergy
        mic.removeLast(mic.count - Int(10 / Lanes.hop))
        let words = Self.words("U", 2, 6) + Self.words("U", 14, 28)
        let result = ChannelAttribution.attribute(
            words: words, micEnergy: mic, systemEnergy: lanes.systemEnergy, hopSeconds: Lanes.hop
        ).words
        let early = Self.words("U", 2, 6).count
        #expect(Set(result.prefix(early).map(\.speakerId)) == [Self.you])
        #expect(Set(result.dropFirst(early).map(\.speakerId)) == [Self.them])
    }

    // MARK: - Shape of the result

    /// Text, order, timings and spacing tokens survive; Scribe's cluster is
    /// kept in `diarizedSpeakerId`; custom ids are used.
    @Test func keepsTheWordsAndRecordsScribesCluster() {
        var lanes = Lanes(seconds: 10)
        lanes.micSpeech(1, 3)
        lanes.systemSpeech(5, 7)
        let words = [
            ScribeWord(text: "hi", start: 1, end: 1.4, type: "word", speakerId: "speaker_3"),
            ScribeWord(text: " ", start: 1.4, end: 1.5, type: "spacing", speakerId: "speaker_3"),
            ScribeWord(text: "there", start: 1.5, end: 2, type: "word", speakerId: "speaker_3"),
            ScribeWord(text: "hello", start: 5, end: 5.5, type: "word", speakerId: "speaker_1"),
        ]
        let result = ChannelAttribution.attribute(
            words: words, micEnergy: lanes.micEnergy, systemEnergy: lanes.systemEnergy,
            hopSeconds: Lanes.hop, youId: "you", themId: "them"
        ).words
        #expect(result.map(\.text) == ["hi", " ", "there", "hello"])
        #expect(result.map(\.start) == words.map(\.start))
        #expect(result.map(\.speakerId) == ["you", "you", "you", "them"])
        #expect(result.map(\.diarizedSpeakerId) == ["speaker_3", "speaker_3", "speaker_3", "speaker_1"])
    }

    /// Re-labelling a stored transcript: the cluster comes from
    /// `diarizedSpeakerId` when present, and it is never overwritten.
    @Test func aRecordedScribeClusterIsTheOneUsed() {
        var lanes = Lanes(seconds: 10)
        lanes.systemSpeech(1, 3)
        let words = [ScribeWord(text: "x", start: 1, end: 1.5, type: "word", speakerId: "speaker_0", diarizedSpeakerId: "speaker_4")]
        let result = Self.attribute(words, lanes)
        #expect(result[0].speakerId == Self.them)
        #expect(result[0].diarizedSpeakerId == "speaker_4")
    }

    /// Stored ids go through snake_case: the new key round-trips.
    @Test func diarizedSpeakerIdRoundTripsThroughStoredJSON() throws {
        let word = ScribeWord(text: "x", start: 1, end: 2, type: "word", speakerId: "speaker_0", diarizedSpeakerId: "speaker_2")
        let data = try MeetingStore.makeEncoder().encode(word)
        #expect(String(decoding: data, as: UTF8.self).contains("\"diarized_speaker_id\""))
        let back = try MeetingStore.makeDecoder().decode(ScribeWord.self, from: data)
        #expect(back.diarizedSpeakerId == "speaker_2")
    }
}
