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
/// - mic voiced, system not: You. System voiced, mic not: Them. "Not" is
///   checked a hop either side, at the leak's lag where one is modelled (the
///   other lane at the same moment, not at the same file offset).
/// - both voiced: leans Them (bleed the leak model missed, or double talk),
///   moved only a little toward a lane clearly nearer its own speaking level
///   than the other is: in double talk, Scribe's cluster decides.
/// - neither: no evidence, except mic sound the leak model accounts for (the
///   remote heard through the speakers), which leans Them, and a quiet voice
///   on a noisy mic (a narrow voice band) with the system lane silent, which
///   leans You a little.
///
/// Scribe's voice cluster is the prior: each cluster leans to the side its
/// own clear words fell on, each of its words with both lanes voiced counting
/// half toward Them; a cluster with neither gets no prior at all (ties go to
/// Them), never the meeting's majority. A two-state pass over the
/// words (Viterbi) makes switching speaker cost more inside a cluster's
/// sentence than across a pause or a cluster change, so one odd word doesn't
/// flip; between two runs of clear, opposite words it costs little, so a short
/// reply Scribe left in the other side's cluster still changes speaker.
///
/// A missing, unreadable or dead mic lane (``LaneLevels/isEmpty``) gives every
/// word to Them: nothing in the mix came from it. With no system lane, or none
/// that ever carries a voice, two voices at the mic keep Scribe's split (an
/// in-room meeting): the one with the most clear words is You.
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
    static let faintScore = 1.0
    static let bothVoicedScore = -0.5
    static let priorLimit = 1.5
    /// A word with both lanes voiced weighs this much of a clear Them word in its cluster's prior.
    static let bothLanesWeight = 0.5
    /// A lane is a word's own when it covers this share of the word's hops.
    static let coverage = 0.25
    /// The other lane must stay silent this far either side of a clear word.
    static let paddingSeconds = 0.05
    /// Both lanes voiced: a lane this many dB nearer its side's speaking level
    /// than the other lane is to its own dominates.
    static let dominanceDB: Float = 10
    /// A side's speaking level comes from at least this many clear words.
    /// With fewer of the user's, the mic's own voiced median stands in only on
    /// a mic that doesn't hear the remote (otherwise no word dominates); with
    /// fewer of the remote's, the system lane's own voiced median stands in.
    static let minimumReferenceWords = 20
    /// The mic hears the remote when it is voiced under this share of the
    /// remote's speech (at their usual level). Only a mic that doesn't, or a
    /// word with a leak taken off, may dominate toward You.
    static let quietMicShare = 0.05
    /// A clear mic word this many words away, in the same stretch, vouches
    /// for the mic on a both-voiced word (it may then dominate toward You).
    static let vouchingWords = 3
    /// A hop is the lane's own voice only this far above the leak predicted on it.
    static let leakMarginDB: Float = 6
    /// The system lane carries nobody when its voice adds up to no more than
    /// this (notification sounds), or this share of the meeting.
    static let silentSystemSeconds = 2.0
    static let silentSystemShare = 0.005
    // The price of changing speaker between two words: inside one cluster's
    // sentence (under 0.3 s apart), across a short pause (under 1 s) in the same
    // cluster, and otherwise (a longer pause, or Scribe heard another voice).
    // Between two runs of at least two clear, opposite words, never more than
    // `switchCost`.
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
        let speech = words.indices.filter { isSpeech(words[$0]) }
        let key = speech.map { clusters[$0] ?? "" }

        func finished(
            _ speechIsYou: [Bool], leak: LeakModel = .none, shared: [String] = [],
            clearMic: [String: Int] = [:], clearSystem: [String: Int] = [:]
        ) -> Attribution {
            var labels = [String](repeating: themId, count: words.count)
            for (k, index) in speech.enumerated() { labels[index] = speechIsYou[k] ? youId : themId }
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

        guard hopSeconds > 0, hopSeconds.isFinite else {
            return finished(Array(repeating: false, count: speech.count))
        }
        let mic = LaneLevels(energy: micEnergy, hopSeconds: hopSeconds)
        let system = LaneLevels(energy: systemEnergy, hopSeconds: hopSeconds)
        if mic.isEmpty {
            return finished(Array(repeating: false, count: speech.count))
        }

        let (lanes, leak) = measure(mic: mic, system: system, hopSeconds: hopSeconds)
        let hops = lanes.count
        let padding = max(1, Int((paddingSeconds / hopSeconds).rounded()))
        var found = speech.map { Self.evidence(for: words[$0], lanes: lanes, hopSeconds: hopSeconds, padding: padding) }

        // Both lanes voiced: each lane against its own side's speaking level,
        // measured on the words the lanes put clearly on that side (a mic's
        // room noise is far below the user speaking; the remote heard faintly
        // is far below the remote's usual level).
        func median(_ values: [Float]) -> Float? {
            values.count < minimumReferenceWords ? nil : values.sorted()[values.count / 2]
        }
        // The system lane carries little but the remote, so its voiced median
        // stands in for the remote's level.
        let remoteLevel = median(found.filter { $0.side == .them }.map(\.systemPeak)) ?? system.speech
        // Does the mic hear the remote? How often it is voiced while the
        // remote speaks at their usual level (a faint open line aside).
        var remoteSpeaking = 0, micVoicedThen = 0
        for hop in 0..<hops where lanes.systemUp[hop] >= 0 && lanes.systemLevel[hop] >= remoteLevel - dominanceDB {
            remoteSpeaking += 1
            if lanes.micUp[hop] >= 0 { micVoicedThen += 1 }
        }
        let micHearsTheRemote = Double(micVoicedThen) >= quietMicShare * Double(max(1, remoteSpeaking))
        // The user's level: measured, or on a mic that doesn't hear the remote
        // (a headset) the mic's own voiced median; elsewhere that median can be
        // room noise or the remote heard out of line.
        let userLevel = median(found.filter { $0.side == .you }.map(\.micPeak))
            ?? (micHearsTheRemote ? nil : mic.speech)
        // A clear mic word within `vouchingWords` of word k, in one stretch
        // (every gap under a second).
        func clearMicWordNearby(_ k: Int) -> Bool {
            for step in [-1, 1] {
                var j = k
                for _ in 0..<vouchingWords {
                    let next = j + step
                    guard found.indices.contains(next) else { break }
                    let (earlier, later) = step < 0 ? (words[speech[next]], words[speech[j]]) : (words[speech[j]], words[speech[next]])
                    let gap = (later.start.flatMap { start in earlier.end.map { start - $0 } }) ?? 0
                    guard gap.isFinite, gap < 1.0 else { break }
                    if found[next].side == .you { return true }
                    j = next
                }
            }
            return false
        }
        for k in found.indices where found[k].side == .bothLanes {
            guard let userLevel else { break }
            let lead = (found[k].micPeak - userLevel) - (found[k].systemPeak - remoteLevel)
            // Toward You only where the mic's sound can be the user's: a leak
            // taken off at this word, a mic that doesn't hear the remote, or a
            // clear mic word beside it in the same stretch. Unmodelled bleed
            // can be louder than the user speaks.
            let mayBeTheUser = found[k].leakModelled || (leak.direction == nil && !micHearsTheRemote)
                || clearMicWordNearby(k)
            if lead >= dominanceDB, mayBeTheUser {
                found[k].score = dominantScore
                found[k].side = nil
            } else if lead <= -dominanceDB {
                found[k].score = -dominantScore
            }
        }
        var evidence = found.map(\.score)
        let clear = found.map(\.side)
        var youCount: [String: Int] = [:], themCount: [String: Int] = [:], bothCount: [String: Int] = [:]
        for (k, side) in clear.enumerated() {
            if side == .you { youCount[key[k], default: 0] += 1 }
            if side == .them { themCount[key[k], default: 0] += 1 }
            if side == .bothLanes { bothCount[key[k], default: 0] += 1 }
        }

        // Two voices at one mic, and nobody on the system lane by the system
        // lane's own account: lanes can't tell them apart, so Scribe's split
        // stands and the voice with the most clear mic words is You.
        let systemVoiced = Double(lanes.systemUp.filter { $0 >= 0 }.count) * hopSeconds
        let nobodyOnSystem = systemVoiced <= max(silentSystemSeconds, silentSystemShare * Double(hops) * hopSeconds)
        let allYou = youCount.values.reduce(0, +)
        let micSide = Set(key).filter { cluster in
            let you = youCount[cluster] ?? 0
            return you >= max(50, allYou / 5) && you >= 2 * (themCount[cluster] ?? 0)
        }.sorted { (youCount[$0] ?? 0, $1) > (youCount[$1] ?? 0, $0) }
        let shared = nobodyOnSystem && micSide.count >= 2 ? Array(micSide.dropFirst()).sorted() : []

        if system.isEmpty {
            // Every sound in the mix came from the mic.
            let isYou = key.map { !shared.contains($0) }
            return finished(isYou, shared: shared, clearMic: youCount, clearSystem: themCount)
        }

        // Each cluster's prior from its own words only: its clear words, and
        // half a Them for each word with both lanes voiced (sound on both at
        // once is usually the remote). Never the meeting's majority.
        var prior: [String: Double] = [:]
        for cluster in Set(key) {
            let you = Double(youCount[cluster] ?? 0) + 1
            let them = Double(themCount[cluster] ?? 0) + bothLanesWeight * Double(bothCount[cluster] ?? 0) + 1
            prior[cluster] = min(priorLimit, max(-priorLimit, log(you / them)))
        }
        for (k, cluster) in key.enumerated() where shared.contains(cluster) {
            evidence[k] = -max(abs(evidence[k]), leaningScore)
        }
        for cluster in shared { prior[cluster] = -priorLimit }

        // Viterbi over You (true) / Them (false). A run is consecutive words
        // whose lane evidence alone (leaning or clear) points the same way.
        let side = evidence.map { $0 >= leaningScore ? 1 : $0 <= -leaningScore ? -1 : 0 }
        var run = [Int](repeating: 0, count: side.count)
        var start = 0
        for k in side.indices where k == side.count - 1 || side[k + 1] != side[k] {
            for j in start...k { run[j] = k - start + 1 }
            start = k + 1
        }
        var scores: [Double] = []
        var switchCosts: [Double] = []
        for (k, index) in speech.enumerated() {
            scores.append(evidence[k] + prior[key[k]]!)
            guard k > 0 else { switchCosts.append(0); continue }
            let previous = words[speech[k - 1]], word = words[index]
            let rawGap = (word.start.flatMap { start in previous.end.map { start - $0 } }) ?? 0
            let gap = rawGap.isFinite ? rawGap : 0
            var cost = key[k] != key[k - 1] ? switchCost
                : gap < 0.3 ? inSentenceSwitchCost : gap < 1.0 ? inPauseSwitchCost : switchCost
            if side[k] != 0, side[k] == -side[k - 1], run[k] >= 2, run[k - 1] >= 2 {
                cost = min(cost, switchCost)
            }
            switchCosts.append(cost)
        }
        return finished(
            viterbi(scores: scores, switchCosts: switchCosts),
            leak: leak, shared: shared, clearMic: youCount, clearSystem: themCount)
    }

    /// A clear word's side, or a word with both lanes voiced and the mic not
    /// clearly ahead (it counts as ``bothLanesWeight`` of a Them in its prior).
    enum Side { case you, them, bothLanes }

    /// Per-hop lane measures the evidence reads (in dB; `-infinity` past a lane's end).
    struct Hops {
        var micUp: [Float], micFaint: [Float], micLevel: [Float]
        /// The mic is over its voice level, but the leak accounts for it.
        var micMasked: [Bool]
        var systemUp: [Float], systemLevel: [Float]
        /// The leak's lag at the hop (`mic[i + lag]` is `system[i]`'s moment), 0 without one.
        var lag: [Int]
        /// A leak is modelled at the hop.
        var leakModelled: [Bool]

        init(count: Int) {
            micUp = [Float](repeating: -.infinity, count: count)
            micFaint = micUp
            micLevel = micUp
            micMasked = [Bool](repeating: false, count: count)
            systemUp = micUp
            systemLevel = micUp
            lag = [Int](repeating: 0, count: count)
            leakModelled = micMasked
        }

        var count: Int { micUp.count }
    }

    /// One word's lane evidence: log-odds for You; for a clear word its side,
    /// or `.bothLanes`; and each lane's peak level (dB) over its voiced hops.
    struct WordEvidence {
        var score: Double
        var side: Side?
        var micPeak = -Float.infinity
        var systemPeak = -Float.infinity
        /// A leak is modelled at the word's first hop.
        var leakModelled = false
    }

    /// Per hop, each lane's height above its own voice level once the leak
    /// from the other lane is taken off (negative: not its voice), and its
    /// level; and the leak found.
    static func measure(mic: LaneLevels, system: LaneLevels, hopSeconds: Double) -> (Hops, LeakModel) {
        let leak = system.isEmpty ? LeakModel.none : LeakModel.estimate(mic: mic, system: system, hopSeconds: hopSeconds)
        var lanes = Hops(count: max(mic.count, system.count))
        for hop in 0..<lanes.count {
            let micLeak = leak.micLeak(at: hop, system: system) + leakMarginDB
            lanes.micUp[hop] = mic[hop] - max(mic.voiced, micLeak)
            lanes.micFaint[hop] = mic[hop] - max(mic.faint, micLeak)
            lanes.micMasked[hop] = mic[hop] >= mic.voiced && mic[hop] < micLeak
            lanes.micLevel[hop] = mic[hop]
            lanes.lag[hop] = leak.lag(at: hop)
            lanes.leakModelled[hop] = leak.isModelled(at: hop)
            guard !system.isEmpty else { continue }
            lanes.systemUp[hop] = system[hop] - max(system.voiced, leak.systemLeak(at: hop, mic: mic) + leakMarginDB)
            lanes.systemLevel[hop] = system[hop]
        }
        return (lanes, leak)
    }

    /// The hops a word spans, or nil when it has no usable timestamps (missing,
    /// not finite, or wholly outside the lanes). A reversed span is one hop.
    static func span(of word: ScribeWord, hopSeconds: Double, hops: Int) -> Range<Int>? {
        guard let start = word.start, let end = word.end, start.isFinite, end.isFinite, hops > 0 else { return nil }
        let length = Double(hops) * hopSeconds
        let from = max(0, start), to = max(start, end)
        guard to >= 0, from < length else { return nil }
        let lower = Int((from / hopSeconds).rounded(.down))
        let upper = min(hops, max(lower + 1, Int((min(to, length) / hopSeconds).rounded(.up))))
        return lower < upper ? lower..<upper : nil
    }

    /// One word's lane evidence. A word with both lanes voiced gets the weak
    /// `bothVoicedScore` here; `attribute` then measures it against each
    /// side's speaking level.
    static func evidence(for word: ScribeWord, lanes: Hops, hopSeconds: Double, padding: Int) -> WordEvidence {
        guard let hops = span(of: word, hopSeconds: hopSeconds, hops: lanes.count) else { return WordEvidence(score: 0) }
        let need = max(1, Int((coverage * Double(hops.count)).rounded(.up)))

        var micHops = 0, faintHops = 0, maskedHops = 0, systemHops = 0
        var micPeak = -Float.infinity, systemPeak = -Float.infinity
        for hop in hops {
            if lanes.micUp[hop] >= 0 { micHops += 1; micPeak = max(micPeak, lanes.micLevel[hop]) }
            if lanes.micFaint[hop] >= 0 { faintHops += 1 }
            if lanes.micMasked[hop] { maskedHops += 1 }
            if lanes.systemUp[hop] >= 0 { systemHops += 1; systemPeak = max(systemPeak, lanes.systemLevel[hop]) }
        }
        func found(_ score: Double, _ side: Side?) -> WordEvidence {
            WordEvidence(score: score, side: side, micPeak: micPeak, systemPeak: systemPeak,
                         leakModelled: lanes.leakModelled[hops.lowerBound])
        }
        // The other lane at the same moment: shifted by the leak's lag.
        let lag = lanes.lag[hops.lowerBound]
        func any(_ values: [Float], shift: Int) -> Bool {
            let lower = max(0, hops.lowerBound - padding + shift), upper = min(lanes.count, hops.upperBound + padding + shift)
            return lower < upper && values[lower..<upper].contains { $0 >= 0 }
        }
        let micNear = any(lanes.micUp, shift: lag)
        let systemNear = any(lanes.systemUp, shift: -lag)
        let micOn = micHops >= need, systemOn = systemHops >= need

        switch (micOn, systemOn) {
        case (true, false):
            return systemNear ? found(leaningScore, nil) : found(clearScore, .you)
        case (false, true):
            return micNear ? found(-leaningScore, nil) : found(-clearScore, .them)
        case (true, true):
            return found(bothVoicedScore, .bothLanes)
        case (false, false):
            // Mic sound the leak accounts for is the other lane's, heard late
            // through the speakers: it leans Them.
            if maskedHops >= need { return found(-leaningScore, nil) }
            return faintHops >= need && systemHops == 0 && !systemNear ? found(faintScore, nil) : found(0, nil)
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
