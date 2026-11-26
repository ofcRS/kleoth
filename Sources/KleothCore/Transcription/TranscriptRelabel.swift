import Foundation

/// Re-attributes the words of a stored cloud transcript (`transcript.json`, the
/// mono Scribe answer) to You/Them from the meeting's lanes, with no Scribe call.
///
/// A transcript stores every word with its timestamps and its You/Them label,
/// but before `diarizedSpeakerId` existed not Scribe's own voice cluster: the
/// attribution overwrote it. For such a meeting the old label stands in for the
/// cluster as the prior (every word of one Scribe cluster had been given the
/// same label), so words the lanes decide are fixed, and words they can't
/// decide keep leaning the way their old label did. That holds only for a
/// transcript whose labels ARE the two lane labels: one with Scribe's own
/// voices (`speaker_0…N`, a CLI transcription) is refused, and so is a meeting
/// without both lanes (the app transcribes those without lanes too).
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
        /// A lane is missing, unreadable or header-only (an empty envelope).
        case laneUnreadable(String)
        /// With no Scribe cluster recorded, a speaker id other than the two
        /// lane labels: the transcript names Scribe's voices, not lanes.
        case notLaneLabels

        public var description: String {
            switch self {
            case .perLaneTranscript: return "each lane was transcribed on its own; nothing to re-attribute"
            case .noWords: return "no timed words"
            case .laneUnreadable(let name): return "no readable \(name), so no lanes to compare"
            case .notLaneLabels:
                return "its speakers are Scribe's voices (speaker_0…N), not the two lanes; re-attributing would merge them"
            }
        }
    }

    /// The re-attributed transcript, or why there is none.
    public static func relabel(
        _ raw: ScribeResponse, micEnergy: [Float], systemEnergy: [Float], hopSeconds: Double
    ) -> Result<Outcome, Refusal> {
        guard raw.transcripts == nil else { return .failure(.perLaneTranscript) }
        guard !micEnergy.isEmpty else { return .failure(.laneUnreadable("mic.m4a")) }
        guard !systemEnergy.isEmpty else { return .failure(.laneUnreadable("system.m4a")) }
        let words = raw.words ?? []
        guard words.contains(where: { $0.start != nil }) else { return .failure(.noWords) }
        let laneLabels: Set<String> = ["speaker_0", "speaker_1"]
        guard words.allSatisfy({ word in
            !ChannelAttribution.isSpeech(word) || word.diarizedSpeakerId != nil
                || word.speakerId.map(laneLabels.contains) == true
        }) else { return .failure(.notLaneLabels) }

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

    /// Marks a folder as a re-labelling preview, so a later run may replace it.
    public static let previewMarkerName = ".relabel-preview"

    /// Why `preview` must not receive a preview of `meeting`, or nil when it
    /// may: it is the meeting itself or lies inside a meeting folder (by any
    /// spelling or symlink), or it holds a meeting's `meta.json`, or a
    /// `transcript.json` that no earlier preview wrote.
    public static func previewProblem(preview: URL, meeting: URL) -> String? {
        let fm = FileManager.default
        func resolved(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
        let target = resolved(preview), source = resolved(meeting)
        if target.path == source.path { return "the preview folder is the meeting folder itself" }
        if target.path.hasPrefix(source.path + "/") { return "the preview folder is inside the meeting folder" }
        var ancestor = target.deletingLastPathComponent()
        while ancestor.path != "/", !ancestor.path.isEmpty {
            let holdsMeeting = ["meta.json", "transcript.json"].contains {
                fm.fileExists(atPath: ancestor.appendingPathComponent($0).path)
            }
            if holdsMeeting { return "the preview folder is inside a meeting folder (\(ancestor.lastPathComponent))" }
            ancestor = ancestor.deletingLastPathComponent()
        }
        if fm.fileExists(atPath: target.appendingPathComponent("meta.json").path) {
            return "the preview folder holds a meeting's meta.json"
        }
        if fm.fileExists(atPath: target.appendingPathComponent("transcript.json").path),
           !fm.fileExists(atPath: target.appendingPathComponent(previewMarkerName).path) {
            return "the preview folder holds a transcript.json no preview wrote"
        }
        return nil
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
