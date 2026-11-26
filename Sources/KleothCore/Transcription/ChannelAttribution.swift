import Foundation

/// Decides, word by word, whether the user (the mic lane, `mic.m4a`) or the
/// remote side (the system lane, `system.m4a`) said each word of a Scribe
/// transcript of the two lanes mixed to mono.
///
/// The mix sums the lanes sample for sample from their first frame, so a
/// word's timestamps are its own lane's time: each word is decided by which
/// lane carries a voice over its span. Each lane is measured against its own
/// floor and voice level (``LaneLevels``), never the other lane's loudness, and
/// is first cleared of what the other lane leaks into it (``LeakModel``: the
/// speakers into the mic, or the mic played back on the system lane):
/// - mic voiced, system not: You. System voiced, mic not: Them.
/// - both voiced: Them (bleed the leak model missed, or double talk), unless
///   one lane is clearly further above its own voice level than the other.
/// - neither: no evidence.
///
/// Scribe's voice cluster is the prior: each cluster leans to the side its
/// clear words fell on (a cluster with no clear mic words leans Them, so a
/// silent mic gives no word to You), and a two-state pass over the words
/// (Viterbi) makes switching speaker cost more inside a cluster's sentence
/// than across a pause or a cluster change, so one odd word doesn't flip.
///
/// A lane that is missing or unreadable (an empty envelope) gives every word to
/// the other lane: nothing in the mix came from it.
public enum ChannelAttribution {
    /// The attributed words, and what the lanes showed.
    public struct Attribution: Sendable {
        /// The words with `speakerId` set to You or Them and Scribe's cluster
        /// kept in `diarizedSpeakerId`.
        public var words: [ScribeWord]
        /// Seconds of the meeting in which the mic was found to hear the
        /// system lane (speakers).
        public var micHearsSystemSeconds: Double
        /// Seconds in which the system lane was found to carry the mic.
        public var systemHearsMicSeconds: Double
        /// Scribe clusters given to Them as a second voice at the mic, with
        /// nobody on the system lane (an in-room meeting).
        public var sharedMicClusters: [String]
        /// Per Scribe cluster: its speech tokens, how many the lanes clearly
        /// put on the mic and on the system lane, and how many ended up You.
        public var clusters: [Cluster]
    }

    public struct Cluster: Sendable, Equatable {
        public var id: String
        public var words: Int
        public var clearMic: Int
        public var clearSystem: Int
        public var you: Int
    }

    // Evidence, as log-odds for You over one word.
    static let clearScore = 3.0
    static let dominantScore = 2.5
    static let leaningScore = 1.5
    static let bothVoicedScore = -0.5
    static let priorLimit = 1.5
    /// A lane is a word's own when it covers this share of the word's hops.
    static let coverage = 0.25
    /// The other lane must stay silent this far either side of a clear word.
    static let paddingSeconds = 0.1
    /// Above its own voice level by this many dB more than the other lane: dominant.
    static let dominanceDB: Float = 10
    /// A hop is the lane's own voice only this far above the leak predicted on it.
    static let leakMarginDB: Float = 6
    // The price of changing speaker between two words: inside one cluster's
    // sentence (under 0.3 s apart), across a short pause (under 1 s) in the same
    // cluster, and otherwise (a longer pause, or Scribe heard another voice).
    static let inSentenceSwitchCost = 4.0
    static let inPauseSwitchCost = 1.5
    static let switchCost = 0.5

    /// Attributes every word to `youId` (mic) or `themId` (system).
    ///
    /// - Parameters:
    ///   - words: Scribe's words; `speakerId` (or `diarizedSpeakerId`, when a
    ///     stored transcript recorded it) is Scribe's voice cluster.
    ///   - micEnergy: the mic lane's per-hop RMS (``ChannelAudio`` envelope);
    ///     empty when the lane is missing or unreadable.
    ///   - systemEnergy: the system lane's, likewise.
    ///   - hopSeconds: seconds per envelope hop.
    public static func attribute(
        words: [ScribeWord],
        micEnergy: [Float],
        systemEnergy: [Float],
        hopSeconds: Double,
        youId: String = "speaker_0",
        themId: String = "speaker_1"
    ) -> Attribution {
        let clusters = words.map { $0.diarizedSpeakerId ?? $0.speakerId }
        func finished(
            _ labels: [String], leak: LeakModel = .none, shared: [String] = [],
            clearMic: [String: Int] = [:], clearSystem: [String: Int] = [:]
        ) -> Attribution {
            var result = words
            var summaries: [String: Cluster] = [:]
            for i in result.indices {
                result[i].diarizedSpeakerId = clusters[i]
                result[i].speakerId = labels[i]
                guard isSpeech(words[i]) else { continue }
                let id = clusters[i] ?? ""
                var summary = summaries[id] ?? Cluster(
                    id: id, words: 0, clearMic: clearMic[id] ?? 0, clearSystem: clearSystem[id] ?? 0, you: 0)
                summary.words += 1
                if labels[i] == youId { summary.you += 1 }
                summaries[id] = summary
            }
            return Attribution(
                words: result,
                micHearsSystemSeconds: leak.direction == .systemIntoMic ? leak.seconds : 0,
                systemHearsMicSeconds: leak.direction == .micIntoSystem ? leak.seconds : 0,
                sharedMicClusters: shared,
                clusters: summaries.values.sorted { $0.id < $1.id }
            )
        }

        let mic = LaneLevels(energy: micEnergy)
        let system = LaneLevels(energy: systemEnergy)
        if mic.isEmpty || hopSeconds <= 0 {
            return finished(Array(repeating: themId, count: words.count))
        }
        if system.isEmpty {
            return finished(Array(repeating: youId, count: words.count))
        }

        // Per hop: how far each lane is above its own voice level, once the
        // leak from the other lane is taken off (negative: not its voice).
        let leak = LeakModel.estimate(mic: mic, system: system, hopSeconds: hopSeconds)
        let hops = max(mic.count, system.count)
        var micUp = [Float](repeating: -.infinity, count: hops)
        var systemUp = [Float](repeating: -.infinity, count: hops)
        for hop in 0..<hops {
            micUp[hop] = mic[hop] - max(mic.voiced, leak.micLeak(at: hop, system: system) + leakMarginDB)
            systemUp[hop] = system[hop] - max(system.voiced, leak.systemLeak(at: hop, mic: mic) + leakMarginDB)
        }

        // The speech tokens (spacing takes its neighbour's label at the end).
        let speech = words.indices.filter { isSpeech(words[$0]) }
        let padding = max(1, Int((paddingSeconds / hopSeconds).rounded()))
        var evidence: [Double] = []
        var clear: [Side?] = []
        for index in speech {
            let (score, side) = Self.evidence(
                for: words[index], micUp: micUp, systemUp: systemUp, hopSeconds: hopSeconds, padding: padding)
            evidence.append(score)
            clear.append(side)
        }

        // Each cluster's prior from its clear words, shrunk toward the meeting's.
        let key = speech.map { clusters[$0] ?? "" }
        var youCount: [String: Int] = [:], themCount: [String: Int] = [:]
        for (k, side) in clear.enumerated() {
            if side == .you { youCount[key[k], default: 0] += 1 }
            if side == .them { themCount[key[k], default: 0] += 1 }
        }
        let allYou = youCount.values.reduce(0, +), allThem = themCount.values.reduce(0, +)
        let share = (Double(allYou) + 0.5) / Double(allYou + allThem + 1)
        var prior: [String: Double] = [:]
        for cluster in Set(key) {
            let you = Double(youCount[cluster] ?? 0) + 2 * share
            let them = Double(themCount[cluster] ?? 0) + 2 * (1 - share)
            prior[cluster] = min(priorLimit, max(-priorLimit, log(you / them)))
        }

        // Two voices at one mic with nobody on the system lane: lanes can't
        // tell them apart, so Scribe's split stands and the voice with the most
        // clear words is You.
        func substantial(_ count: Int, of total: Int) -> Bool { count >= max(50, total / 5) }
        let systemSide = Set(key).filter { cluster in
            let them = themCount[cluster] ?? 0
            return substantial(them, of: allThem) && them >= 3 * (youCount[cluster] ?? 0)
        }
        let micSide = Set(key).filter { cluster in
            let you = youCount[cluster] ?? 0
            return substantial(you, of: allYou) && you >= 2 * (themCount[cluster] ?? 0)
        }.sorted { (youCount[$0] ?? 0, $1) > (youCount[$1] ?? 0, $0) }
        var shared: [String] = []
        if systemSide.isEmpty, micSide.count >= 2 {
            shared = Array(micSide.dropFirst()).sorted()
            for (k, cluster) in key.enumerated() where shared.contains(cluster) {
                evidence[k] = -max(abs(evidence[k]), leaningScore)
            }
            for cluster in shared { prior[cluster] = -priorLimit }
        }

        // Viterbi over You (true) / Them (false).
        var scores: [Double] = []
        var switchCosts: [Double] = []
        for (k, index) in speech.enumerated() {
            scores.append(evidence[k] + prior[key[k]]!)
            guard k > 0 else { switchCosts.append(0); continue }
            let previous = words[speech[k - 1]], word = words[index]
            let gap = (word.start.flatMap { start in previous.end.map { start - $0 } }) ?? 0
            let sameCluster = key[k] == key[k - 1]
            switchCosts.append(!sameCluster ? switchCost : gap < 0.3 ? inSentenceSwitchCost
                : gap < 1.0 ? inPauseSwitchCost : switchCost)
        }
        let isYou = viterbi(scores: scores, switchCosts: switchCosts)

        var labels = [String](repeating: themId, count: words.count)
        for (k, index) in speech.enumerated() { labels[index] = isYou[k] ? youId : themId }
        // Spacing and other tokens: the previous speech token's label (the next one's first).
        var last: String? = nil
        var pending: [Int] = []
        for index in words.indices {
            if isSpeech(words[index]) {
                last = labels[index]
                for p in pending { labels[p] = labels[index] }
                pending = []
            } else if let last {
                labels[index] = last
            } else {
                pending.append(index)
            }
        }
        return finished(labels, leak: leak, shared: shared, clearMic: youCount, clearSystem: themCount)
    }

    enum Side { case you, them }

    /// One word's lane evidence (log-odds for You) and, for a clear word, its side.
    static func evidence(
        for word: ScribeWord, micUp: [Float], systemUp: [Float], hopSeconds: Double, padding: Int
    ) -> (Double, Side?) {
        guard let start = word.start, let end = word.end else { return (0, nil) }
        let hops = micUp.count
        let lower = max(0, Int((start / hopSeconds).rounded(.down)))
        let upper = min(hops, max(lower + 1, Int((end / hopSeconds).rounded(.up))))
        guard lower < upper else { return (0, nil) }
        let need = max(1, Int((coverage * Double(upper - lower)).rounded(.up)))

        var micHops = 0, systemHops = 0
        var micPeak = -Float.infinity, systemPeak = -Float.infinity
        for hop in lower..<upper {
            if micUp[hop] >= 0 { micHops += 1 }
            if systemUp[hop] >= 0 { systemHops += 1 }
            micPeak = max(micPeak, micUp[hop])
            systemPeak = max(systemPeak, systemUp[hop])
        }
        var micNear = false, systemNear = false
        for hop in max(0, lower - padding)..<min(hops, upper + padding) {
            if micUp[hop] >= 0 { micNear = true }
            if systemUp[hop] >= 0 { systemNear = true }
        }
        let micOn = micHops >= need, systemOn = systemHops >= need

        switch (micOn, systemOn) {
        case (true, false):
            return systemNear ? (leaningScore, nil) : (clearScore, .you)
        case (false, true):
            return micNear ? (-leaningScore, nil) : (-clearScore, .them)
        case (true, true):
            let lead = micPeak - systemPeak
            if lead >= dominanceDB { return (dominantScore, .you) }
            if lead <= -dominanceDB { return (-dominantScore, .them) }
            return (bothVoicedScore, nil)
        case (false, false):
            return (0, nil)
        }
    }

    /// The likeliest You/Them sequence: `scores[k]` is word k's log-odds for
    /// You, `switchCosts[k]` the price of changing speaker between k-1 and k.
    /// Ties go to Them.
    static func viterbi(scores: [Double], switchCosts: [Double]) -> [Bool] {
        guard !scores.isEmpty else { return [] }
        var you = scores[0] / 2, them = -scores[0] / 2
        var fromYou: [(you: Bool, them: Bool)] = [(true, false)]
        for k in 1..<scores.count {
            let cost = switchCosts[k]
            let youStay = you, youSwitch = them - cost
            let themStay = them, themSwitch = you - cost
            let nextYou = max(youStay, youSwitch) + scores[k] / 2
            let nextThem = max(themStay, themSwitch) - scores[k] / 2
            // Did the best path into You (into Them) at k come from You? Ties stay put.
            fromYou.append((you: youStay >= youSwitch, them: themSwitch > themStay))
            you = nextYou
            them = nextThem
        }
        var result = [Bool](repeating: false, count: scores.count)
        var state = you > them
        for k in stride(from: scores.count - 1, through: 0, by: -1) {
            result[k] = state
            if k > 0 { state = state ? fromYou[k].you : fromYou[k].them }
        }
        return result
    }

    /// A word or an audio event (laughter belongs to a lane too); spacing is not.
    static func isSpeech(_ word: ScribeWord) -> Bool {
        switch word.type {
        case "word", "audio_event", nil: return true
        default: return false
        }
    }
}
