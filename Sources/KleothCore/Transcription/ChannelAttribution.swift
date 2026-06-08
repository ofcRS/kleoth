import Foundation

/// Attributes each transcript word to a speaker by comparing per-channel audio
/// energy at the word's timestamp.
///
/// The validated mono-Scribe path mixes `mic.m4a` + `system.m4a` down to a
/// single mono track (1× cost, correct duration) and sends that to Scribe. Each
/// transcribed word is then attributed to `speaker_0` (You / mic) or `speaker_1`
/// (Them / system) by whichever channel is louder over the word's time span.
/// Scribe's own diarization is not used (it scored only 61.8% on this task).
public enum ChannelAttribution {
    /// Returns a copy of `words` with each word's `speakerId` set to whichever
    /// channel had more energy over its `[start, end]` span.
    ///
    /// - Parameters:
    ///   - words: the transcribed words (timestamps in seconds).
    ///   - channel0Energy: per-hop energy for channel 0 (→ `speaker0Id`).
    ///   - channel1Energy: per-hop energy for channel 1 (→ `speaker1Id`).
    ///   - hopSeconds: seconds of audio represented by each energy sample.
    ///   - speaker0Id: id assigned when channel 0 is louder (or on ties).
    ///   - speaker1Id: id assigned when channel 1 is louder.
    ///
    /// A word with no timestamps, or whose span has ≈0 energy on both channels,
    /// carries the previous word's assignment (defaulting to `speaker0Id` for
    /// the very first word). On a tie, `speaker0Id` wins.
    public static func assignSpeakers(
        words: [ScribeWord],
        channel0Energy: [Float],
        channel1Energy: [Float],
        hopSeconds: Double,
        speaker0Id: String = "speaker_0",
        speaker1Id: String = "speaker_1"
    ) -> [ScribeWord] {
        let count = min(channel0Energy.count, channel1Energy.count)
        var previous = speaker0Id

        return words.map { word in
            var assigned = previous

            if let start = word.start, let end = word.end, hopSeconds > 0, count > 0 {
                let lower = max(0, Int((start / hopSeconds).rounded(.down)))
                let upperRaw = Int((end / hopSeconds).rounded(.up))
                let upper = min(upperRaw, count - 1)

                if lower <= upper {
                    var sum0: Double = 0
                    var sum1: Double = 0
                    for i in lower...upper {
                        sum0 += Double(channel0Energy[i])
                        sum1 += Double(channel1Energy[i])
                    }
                    // Both channels effectively silent: keep the previous speaker.
                    if sum0 >= 1e-9 || sum1 >= 1e-9 {
                        assigned = sum0 >= sum1 ? speaker0Id : speaker1Id
                    }
                }
            }

            previous = assigned
            var updated = word
            updated.speakerId = assigned
            return updated
        }
    }

    /// Relabels Scribe-**diarized** words to You/Them by mapping each diarization
    /// *cluster* (Scribe's `speaker_id`) to the channel it correlates with —
    /// mic → `speaker0Id` (You), system → `speaker1Id` (Them).
    ///
    /// Unlike ``assignSpeakers`` (one energy decision per word, which flips
    /// mid-utterance), this makes the channel decision **once per cluster** over
    /// all of that cluster's words, so a whole turn stays on one speaker. Scribe
    /// already grouped the words by voice; we only resolve which voice is You.
    ///
    /// Clusters are split by **relative** channel affinity, not absolute energy:
    /// the most mic-leaning cluster becomes You and the most system-leaning
    /// becomes Them, so a mic that bleeds the far end (both clusters louder on
    /// channel 0) still separates the two speakers instead of collapsing them.
    /// Any additional clusters fall to whichever channel they individually lean
    /// toward. Words without a cluster id are left untouched.
    public static func mapDiarizedSpeakers(
        words: [ScribeWord],
        channel0Energy: [Float],
        channel1Energy: [Float],
        hopSeconds: Double,
        speaker0Id: String = "speaker_0",
        speaker1Id: String = "speaker_1"
    ) -> [ScribeWord] {
        let count = min(channel0Energy.count, channel1Energy.count)

        // Sum each cluster's energy on both channels over its words' spans.
        var energy0: [String: Double] = [:]
        var energy1: [String: Double] = [:]
        for word in words {
            guard let cluster = word.speakerId,
                  let start = word.start, let end = word.end,
                  hopSeconds > 0, count > 0 else { continue }
            let lower = max(0, Int((start / hopSeconds).rounded(.down)))
            let upper = min(Int((end / hopSeconds).rounded(.up)), count - 1)
            guard lower <= upper else { continue }
            var sum0 = 0.0
            var sum1 = 0.0
            for i in lower...upper {
                sum0 += Double(channel0Energy[i])
                sum1 += Double(channel1Energy[i])
            }
            energy0[cluster, default: 0] += sum0
            energy1[cluster, default: 0] += sum1
        }

        // Relative affinity to channel 0: +1 = all mic, -1 = all system, 0 = even.
        func affinity(_ cluster: String) -> Double {
            let a = energy0[cluster, default: 0]
            let b = energy1[cluster, default: 0]
            let total = a + b
            return total > 0 ? (a - b) / total : 0
        }

        let clusters = Set(words.compactMap(\.speakerId))
        var mapping: [String: String] = [:]
        if clusters.count >= 2 {
            // Most mic-leaning cluster → You; most system-leaning → Them; force
            // them distinct so bleed can't merge both onto one speaker. The sort
            // is a *total* order (affinity desc, then cluster id asc) so equal-
            // affinity clusters — e.g. two near-silent ones — can't flip You/Them
            // between launches via randomized Set iteration order.
            let ranked = clusters.sorted { a, b in
                let fa = affinity(a), fb = affinity(b)
                return fa != fb ? fa > fb : a < b
            }
            mapping[ranked.first!] = speaker0Id
            mapping[ranked.last!] = speaker1Id
            for cluster in ranked.dropFirst().dropLast() {
                mapping[cluster] = affinity(cluster) >= 0 ? speaker0Id : speaker1Id
            }
        } else {
            for cluster in clusters {
                mapping[cluster] = affinity(cluster) >= 0 ? speaker0Id : speaker1Id
            }
        }

        return words.map { word in
            guard let cluster = word.speakerId, let mapped = mapping[cluster] else { return word }
            var updated = word
            updated.speakerId = mapped
            return updated
        }
    }
}
