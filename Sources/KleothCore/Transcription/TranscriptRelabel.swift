import Foundation

/// Re-attributes the words of a stored cloud transcript (`transcript.json`, the
/// mono Scribe answer) to You/Them from the meeting's lanes, with no Scribe call.
///
/// A transcript stores every word with its timestamps and its You/Them label,
/// but before `diarizedSpeakerId` existed not Scribe's own voice cluster: the
/// attribution overwrote it. For such a meeting the old label stands in for the
/// cluster as the prior (every word of one Scribe cluster had been given the
/// same label), so words the lanes decide are fixed, and words they can't
/// decide keep leaning the way their old label did.
public enum TranscriptRelabel {
    public struct Outcome: Sendable {
        /// The transcript with the new labels; everything else as it was.
        public var response: ScribeResponse
        /// Speech tokens (words and audio events).
        public var words: Int
        public var youBefore: Int
        public var youAfter: Int
        /// Speech tokens whose label changed.
        public var changed: Int
        /// Whether the transcript recorded Scribe's clusters (`diarizedSpeakerId`).
        public var usedScribeClusters: Bool
        public var micHearsSystemSeconds: Double
        public var systemHearsMicSeconds: Double
        public var sharedMicClusters: Int
        /// Per old label (or Scribe cluster): counts, as ``ChannelAttribution/Cluster``.
        public var clusters: [ChannelAttribution.Cluster]
    }

    /// Why a transcript can't be re-attributed.
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        /// On-device or multichannel: each lane was transcribed on its own.
        case perLaneTranscript
        /// No timed words.
        case noWords

        public var description: String {
            switch self {
            case .perLaneTranscript: return "each lane was transcribed on its own; nothing to re-attribute"
            case .noWords: return "no timed words"
            }
        }
    }

    /// The re-attributed transcript, or why there is none.
    public static func relabel(
        _ raw: ScribeResponse, micEnergy: [Float], systemEnergy: [Float], hopSeconds: Double
    ) -> Result<Outcome, Refusal> {
        guard raw.transcripts == nil else { return .failure(.perLaneTranscript) }
        let words = raw.words ?? []
        guard words.contains(where: { $0.start != nil }) else { return .failure(.noWords) }

        let attribution = ChannelAttribution.attribute(
            words: words, micEnergy: micEnergy, systemEnergy: systemEnergy, hopSeconds: hopSeconds)
        var relabelled = attribution.words
        // Never record an old label as Scribe's cluster.
        for i in relabelled.indices { relabelled[i].diarizedSpeakerId = words[i].diarizedSpeakerId }

        let speech = words.indices.filter { ChannelAttribution.isSpeech(words[$0]) }
        let you = "speaker_0"
        var response = raw
        response.words = relabelled
        return .success(Outcome(
            response: response,
            words: speech.count,
            youBefore: speech.filter { words[$0].speakerId == you }.count,
            youAfter: speech.filter { relabelled[$0].speakerId == you }.count,
            changed: speech.filter { words[$0].speakerId != relabelled[$0].speakerId }.count,
            usedScribeClusters: words.contains { $0.diarizedSpeakerId != nil },
            micHearsSystemSeconds: attribution.micHearsSystemSeconds,
            systemHearsMicSeconds: attribution.systemHearsMicSeconds,
            sharedMicClusters: attribution.sharedMicClusters.count,
            clusters: attribution.clusters
        ))
    }

    /// Whether two transcripts hold the same words at the same times (labels
    /// aside): a backup belongs to the transcript next to it.
    public static func sameWords(_ a: ScribeResponse, _ b: ScribeResponse) -> Bool {
        let left = a.words ?? [], right = b.words ?? []
        return left.count == right.count && zip(left, right).allSatisfy { x, y in
            x.text == y.text && x.start == y.start && x.end == y.end && x.type == y.type
        }
    }
}
