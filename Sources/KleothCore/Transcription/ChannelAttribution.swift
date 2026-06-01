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
}
