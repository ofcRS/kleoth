import Foundation
import Testing
@testable import KleothCore

/// The edges of per-word attribution where the lanes say little: a quiet user,
/// a remote who barely speaks, bleed too short to model, short replies, a dead
/// or missing lane, strange timestamps. Losing the user's real words is as bad
/// as giving them the remote's: with weak evidence, Scribe's split stands.
@Suite struct ChannelAttributionEdgeTests {
    typealias Lanes = ChannelAttributionTests.Lanes
    private static let you = "speaker_0"
    private static let them = "speaker_1"

    private static func words(_ cluster: String?, _ from: Double, _ to: Double) -> [ScribeWord] {
        ChannelAttributionTests.words(cluster, from, to)
    }

    private static func bursts(_ from: Double, _ to: Double) -> [(Double, Double)] {
        ChannelAttributionTests.bursts(from, to)
    }

    private static func run(_ words: [ScribeWord], _ lanes: Lanes) -> ChannelAttribution.Attribution {
        ChannelAttribution.attribute(
            words: words, micEnergy: lanes.micEnergy, systemEnergy: lanes.systemEnergy, hopSeconds: Lanes.hop)
    }

    private static func labels(_ attribution: ChannelAttribution.Attribution, cluster: String) -> Set<String?> {
        ChannelAttributionTests.labels(attribution.words, cluster: cluster)
    }

    /// A quiet user on a noisy mic: steady noise at -50 dB, the user's peaks
    /// only 8 or 11 dB above it.
    @Test(arguments: [Float(8), 11])
    func aQuietUserOnANoisyMicKeepsTheirWords(snr: Float) {
        var lanes = Lanes(seconds: 200, micFloor: -50, systemFloor: -90)
        var words: [ScribeWord] = []
        for (index, (from, to)) in Self.bursts(0, 190).enumerated() {
            if index % 2 == 0 {
                lanes.systemSpeech(from, to)
                words += Self.words("R", from, to)
            } else {
                lanes.micSpeech(from, to, at: -50 + snr)
                words += Self.words("U", from, to)
            }
        }
        let attribution = Self.run(words, lanes)
        #expect(Self.labels(attribution, cluster: "U") == [Self.you])
        #expect(Self.labels(attribution, cluster: "R") == [Self.them])
    }

    /// Scribe splits the user into two clusters and the remote says only a few
    /// seconds: the system lane has a voice, so this is a call, not two people
    /// at one mic. Both user clusters are You.
    @Test(arguments: [8.0, 14.0])
    func aUserSplitInTwoClustersOnACallStaysYou(remoteSeconds: Double) {
        var lanes = Lanes(seconds: 310 + remoteSeconds)
        var words: [ScribeWord] = []
        for (index, (from, to)) in Self.bursts(0, 280).enumerated() {
            lanes.micSpeech(from, to)
            words += Self.words(index % 3 == 2 ? "U2" : "U1", from, to)
        }
        lanes.systemSpeech(301, 301 + remoteSeconds)
        words += Self.words("R", 301, 301 + remoteSeconds)

        let attribution = Self.run(words, lanes)
        #expect(Self.labels(attribution, cluster: "U1") == [Self.you])
        #expect(Self.labels(attribution, cluster: "U2") == [Self.you])
        #expect(Self.labels(attribution, cluster: "R") == [Self.them])
        #expect(attribution.sharedMicClusters.isEmpty)
    }

    /// A short meeting on laptop speakers: too little remote voice (10 or 18 s)
    /// for a leak model, so every remote word has the mic loud too. The remote's
    /// cluster has no clear word; it must not inherit the user's majority.
    @Test(arguments: [10.0, 18.0])
    func bleedTooShortToModelKeepsTheRemoteThem(remoteTotal: Double) {
        var lanes = Lanes(seconds: 90, micFloor: -71, systemFloor: -99)
        var words: [ScribeWord] = []
        var remoteSoFar = 0.0
        for (from, to) in Self.bursts(0, 85) {
            if remoteSoFar < remoteTotal, Int(from) % 2 == 0 {
                lanes.systemSpeech(from, to)
                words += Self.words("R", from, to)
                remoteSoFar += to - from
            } else {
                lanes.micSpeech(from, to, at: -30)
                words += Self.words("U", from, to)
            }
        }
        lanes.bleedSystemIntoMic(gain: -9, lag: 0.05)

        let attribution = Self.run(words, lanes)
        #expect(attribution.micHearsSystemSeconds == 0)
        #expect(Self.labels(attribution, cluster: "R") == [Self.them])
        #expect(Self.labels(attribution, cluster: "U") == [Self.you])
    }

    /// On speakers, the user answers 0.1 s after the remote stops, in a few
    /// words Scribe kept in the remote's cluster.
    @Test(arguments: [2, 4])
    func aShortReplyInTheRemotesClusterIsYou(replyWords: Int) {
        var lanes = Lanes(seconds: 200, micFloor: -71, systemFloor: -99)
        var words: [ScribeWord] = []
        var replies: [(Double, Double)] = []
        for (index, from) in stride(from: 0.0, to: 180.0, by: 9.0).enumerated() {
            let to = from + 4
            lanes.systemSpeech(from, to)
            words += Self.words("R", from, to)
            if index % 2 == 1 { replies.append((to + 0.1, to + 0.1 + Double(replyWords) * 0.3 - 0.05)) }
        }
        lanes.bleedSystemIntoMic(gain: -9, lag: 0.05)
        for (from, to) in replies {
            lanes.micSpeech(from, to, at: -30)
            words += Self.words("R", from, to).map { var word = $0; word.text = "reply"; return word }
        }
        words.sort { $0.start! < $1.start! }

        let result = Self.run(words, lanes).words
        #expect(Set(result.filter { $0.text == "reply" }.map(\.speakerId)) == [Self.you])
        #expect(Set(result.filter { $0.text != "reply" }.map(\.speakerId)) == [Self.them])
    }

    /// Lanes offset by 0.3 s (the mic file ahead of the system lane, on
    /// speakers): a two-word reply that starts 0.3 s after the remote stops
    /// starts right as the remote's last syllable ends in file time. Read at
    /// the leak's lag, the system lane is silent around the reply.
    @Test func crossLaneChecksReadTheOtherLaneAtTheLeaksLag() {
        var lanes = Lanes(seconds: 200, micFloor: -71, systemFloor: -99)
        var words: [ScribeWord] = []
        var replies: [(Double, Double)] = []
        for (index, from) in stride(from: 0.0, to: 180.0, by: 9.0).enumerated() {
            let to = from + 4
            lanes.systemSpeech(from, to)
            words += Self.words("R", from, to)
            if index % 2 == 1 { replies.append((to, to + 0.55)) }
        }
        lanes.bleedSystemIntoMic(gain: -9, lag: -0.3)
        for (from, to) in replies {
            lanes.micSpeech(from, to, at: -30)
            words += Self.words("R", from, to).map { var word = $0; word.text = "reply"; return word }
        }
        words.sort { $0.start! < $1.start! }

        let attribution = Self.run(words, lanes)
        #expect(attribution.micHearsSystemSeconds > 0)
        #expect(Set(attribution.words.filter { $0.text == "reply" }.map(\.speakerId)) == [Self.you])
        // The first word of each reply is clear, not merely leaning.
        let (hops, _) = ChannelAttribution.measure(
            mic: LaneLevels(energy: lanes.micEnergy, hopSeconds: Lanes.hop),
            system: LaneLevels(energy: lanes.systemEnergy, hopSeconds: Lanes.hop), hopSeconds: Lanes.hop)
        let firsts = words.indices.filter { words[$0].text == "reply" && words[$0 - 1].text != "reply" }
        for index in firsts {
            let found = ChannelAttribution.evidence(for: words[index], lanes: hops, hopSeconds: Lanes.hop, padding: 1)
            #expect(found.score == ChannelAttribution.clearScore && found.side == .you)
        }
    }

    /// A headset that leaks some of the remote's turns, faintly, into the mic,
    /// with the lanes offset so the system lane's copy comes 0.25 s after the
    /// mic's. The system lane does not carry the user: what it shares with the
    /// mic is far below how loud the user speaks, so those turns stay Them.
    @Test func faintBleedWithTheSystemLaneLateIsNotTheUsersVoicePlayedBack() {
        var lanes = Lanes(seconds: 400)
        var words: [ScribeWord] = []
        var leaked: [(Double, Double)] = []
        for (index, (from, to)) in Self.bursts(0, 240).enumerated() {
            lanes.systemSpeech(from, to)
            words += Self.words("R", from, to)
            if index % 3 == 0 { leaked.append((from, to)) }
        }
        for (from, to) in Self.bursts(250, 390) {
            lanes.micSpeech(from, to, at: -15)
            words += Self.words("U", from, to)
        }
        let source = lanes.system
        for (from, to) in leaked {
            for i in Lanes.hops(from, to, count: source.count) where i - 5 >= 0 {
                lanes.mic[i - 5] = max(lanes.mic[i - 5], source[i] - 12)
            }
        }
        let attribution = Self.run(words, lanes)
        #expect(attribution.systemHearsMicSeconds == 0)
        #expect(Self.labels(attribution, cluster: "R") == [Self.them])
        #expect(Self.labels(attribution, cluster: "U") == [Self.you])
    }

    /// Speakers in a reverberant room: the mic hears the remote smeared over a
    /// second, so no leak lines up, and the room rings on past the end of each
    /// remote turn. The remote's words have both lanes loud; the few that fall
    /// in the ringing look mic-only. Both lanes loud at once is the remote, so
    /// the cluster stays Them: a handful of clear mic words must not outvote
    /// hundreds of both-voiced ones.
    @Test func aClusterMostlyOnBothLanesLeansThem() {
        var lanes = Lanes(seconds: 300, micFloor: -71, systemFloor: -99)
        var words: [ScribeWord] = []
        for (index, (from, to)) in Self.bursts(0, 290).enumerated() {
            if index % 4 == 0 {
                lanes.micSpeech(from, to, at: -26)
                words += Self.words("U", from, to)
            } else {
                lanes.systemSpeech(from, to)
                words += Self.words("R", from, to + 0.6)  // the last words fall in the ringing
            }
        }
        // The mic keeps only the remote turns' on/off shape, with a texture of
        // its own (a processed, reverberant pickup).
        let source = lanes.system
        for j in lanes.mic.indices {
            let ringing = (max(0, j - 12)...min(source.count - 1, j)).contains { source[$0] > -60 }
            if ringing { lanes.mic[j] = max(lanes.mic[j], -34 - 2 * Lanes.syllable(j, voice: 9)) }
        }
        let attribution = Self.run(words, lanes)
        #expect(attribution.micHearsSystemSeconds == 0)
        #expect(Self.labels(attribution, cluster: "U") == [Self.you])
        let remote = attribution.words.filter { $0.diarizedSpeakerId == "R" }
        #expect(remote.filter { $0.speakerId == Self.you }.count <= remote.count / 20)
    }

    /// A noisy room on a quiet mic: noise well over the mic's floor most of the
    /// time, the user speaking far louder than it. The user's cluster (an old
    /// label, as a stored meeting has) also holds some of the remote's turns:
    /// the system lane at the remote's usual level, the mic only noise. Each
    /// side is measured against its own speaking level, from its clear words:
    /// those turns are the remote's.
    @Test func roomNoiseUnderTheRemoteIsNotTheUsersVoice() {
        var lanes = Lanes(seconds: 300, micFloor: -83, systemFloor: -86)
        for i in lanes.mic.indices where (i / 7) % 3 != 0 {
            lanes.mic[i] = max(lanes.mic[i], -58 - Lanes.syllable(i, voice: 11))
        }
        var words: [ScribeWord] = []
        var mislabelled: [ScribeWord] = []
        for (index, (from, to)) in Self.bursts(0, 290).enumerated() {
            if index % 6 == 0 {
                lanes.micSpeech(from, to, at: -40)
                words += Self.words("U", from, to)
            } else {
                lanes.systemSpeech(from, to)
                let inUser = index == 13 || index == 37
                let remote = Self.words(inUser ? "U" : "R", from, to)
                if inUser { mislabelled += remote }
                words += remote
            }
        }
        let attribution = Self.run(words, lanes)
        #expect(attribution.micHearsSystemSeconds == 0)
        let times = Set(mislabelled.map(\.start))
        let remoteInUserCluster = attribution.words.filter { times.contains($0.start) }
        #expect(remoteInUserCluster.filter { $0.speakerId == Self.you }.count <= remoteInUserCluster.count / 20)
        let user = attribution.words.filter { $0.diarizedSpeakerId == "U" && !times.contains($0.start) }
        #expect(user.allSatisfy { $0.speakerId == Self.you })
    }

    /// Laptop speakers louder on the mic than the user's own voice, with the
    /// leak modelled only in the first half (in the second the room smears it
    /// out of line). Where no leak is modelled, both lanes loud is not the user,
    /// however loud the mic is next to the user's own speaking level.
    @Test func bleedWhereNoLeakIsModelledIsNotTheUser() {
        var lanes = Lanes(seconds: 300, micFloor: -71, systemFloor: -99)
        var words: [ScribeWord] = []
        var smeared: [(Double, Double)] = []
        for (index, (from, to)) in Self.bursts(0, 290).enumerated() {
            if index % 4 == 0 {
                lanes.micSpeech(from, to, at: -40)
                words += Self.words("U", from, to)
            } else {
                lanes.systemSpeech(from, to)
                words += Self.words("R", from, to)
                if from >= 150 { smeared.append((from, to)) }
            }
        }
        let source = lanes.system
        for j in lanes.mic.indices where j >= 1 {
            let i = j - 1
            if Double(i) * Lanes.hop < 150 {
                lanes.mic[j] = max(lanes.mic[j], source[i] - 9)
            }
        }
        for (from, to) in smeared {
            for j in Lanes.hops(from, to + 0.4, count: lanes.mic.count) {
                lanes.mic[j] = max(lanes.mic[j], -26 - 2 * Lanes.syllable(j, voice: 9))
            }
        }
        let attribution = Self.run(words, lanes)
        #expect(attribution.micHearsSystemSeconds > 0)
        let remote = attribution.words.filter { $0.diarizedSpeakerId == "R" }
        #expect(remote.filter { $0.speakerId == Self.you }.count <= remote.count / 20)
        #expect(Self.labels(attribution, cluster: "U") == [Self.you])
    }

    /// Two people at one mic and no readable system lane: Scribe's split stands.
    @Test func twoVoicesAtTheMicWithNoSystemLaneKeepScribesSplit() {
        var lanes = Lanes(seconds: 240)
        var words: [ScribeWord] = []
        for (index, (from, to)) in Self.bursts(0, 230).enumerated() {
            let voice = index % 3 == 2 ? "Q" : "P"
            lanes.micSpeech(from, to, at: voice == "P" ? -22 : -26, voice: voice == "P" ? 1 : 4)
            words += Self.words(voice, from, to)
        }
        let attribution = ChannelAttribution.attribute(
            words: words, micEnergy: lanes.micEnergy, systemEnergy: [], hopSeconds: Lanes.hop)
        #expect(Self.labels(attribution, cluster: "P") == [Self.you])
        #expect(Self.labels(attribution, cluster: "Q") == [Self.them])
    }

    /// A dead mic: its loudest second stays within a few dB of its floor. It is
    /// no lane at all, so nothing is You, even with noise blips under words.
    @Test func aDeadMicGivesNoWords() {
        var lanes = Lanes(seconds: 120)
        var words: [ScribeWord] = []
        for (index, (from, to)) in Self.bursts(0, 110).enumerated() {
            lanes.systemSpeech(from, to, at: index % 2 == 0 ? -18 : -34, voice: index % 2 == 0 ? 2 : 3)
            words += Self.words(index % 2 == 0 ? "A" : "B", from, to)
        }
        for i in stride(from: 0, to: lanes.mic.count, by: 97) { lanes.mic[i] += 4 }  // blips, 0.05 s each
        let result = Self.run(words, lanes).words
        #expect(result.filter { $0.speakerId == Self.you }.isEmpty)
    }

    /// The same quiet mic, but the user does speak, briefly and clearly: those
    /// words are theirs. A rare voice is not a dead mic.
    @Test func aRareRealVoiceOnAnOtherwiseSilentMicSurvives() {
        var lanes = Lanes(seconds: 600)
        var words: [ScribeWord] = []
        for (from, to) in Self.bursts(0, 590) where to < 299 || from > 311 {
            lanes.systemSpeech(from, to)
            words += Self.words("R", from, to)
        }
        lanes.micSpeech(301, 305, at: -30)
        lanes.micSpeech(306, 309, at: -30)
        words = (words + Self.words("U", 301, 305) + Self.words("U", 306, 309)).sorted { $0.start! < $1.start! }

        let attribution = Self.run(words, lanes)
        #expect(Self.labels(attribution, cluster: "U") == [Self.you])
        #expect(Self.labels(attribution, cluster: "R") == [Self.them])
    }

    /// NaN, infinite, huge, negative and reversed timestamps never trap, and
    /// the words around them are still decided.
    @Test func strangeTimestampsDoNotTrap() {
        var lanes = Lanes(seconds: 20)
        lanes.micSpeech(2, 6)
        lanes.systemSpeech(8, 12)
        let strange = [
            ScribeWord(text: "nan", start: .nan, end: .nan, type: "word", speakerId: "Z"),
            ScribeWord(text: "inf", start: 3, end: .infinity, type: "word", speakerId: "Z"),
            ScribeWord(text: "-inf", start: -.infinity, end: 3, type: "word", speakerId: "Z"),
            ScribeWord(text: "huge", start: 1e300, end: 1e301, type: "word", speakerId: "Z"),
            ScribeWord(text: "negative", start: -1, end: -0.5, type: "word", speakerId: "Z"),
            ScribeWord(text: "reversed", start: 4, end: 3.5, type: "word", speakerId: "Z"),
            ScribeWord(text: "past", start: 25, end: 26, type: "word", speakerId: "Z"),
        ]
        let words = Self.words("U", 2, 6) + strange + Self.words("R", 8, 12)
        let attribution = Self.run(words, lanes)
        #expect(attribution.words.count == words.count)
        #expect(Self.labels(attribution, cluster: "U") == [Self.you])
        #expect(Self.labels(attribution, cluster: "R") == [Self.them])
    }
}
