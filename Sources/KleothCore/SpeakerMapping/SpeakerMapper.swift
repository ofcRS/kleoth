import Foundation

/// Applies a `SpeakerMap` to a transcript and extracts representative
/// samples per speaker (used to help a human assign real names).
public enum SpeakerMapper {
    /// Returns a copy of `transcript` with `speakerName` populated from `map`.
    ///
    /// Each utterance's `speakerName` is set to `map.names[speakerId]`; when
    /// the map has no entry for a speaker, the name is left `nil`.
    public static func apply(_ map: SpeakerMap, to transcript: Transcript) -> Transcript {
        var copy = transcript
        copy.utterances = transcript.utterances.map { utterance in
            var updated = utterance
            updated.speakerName = map.names[utterance.speakerId]
            return updated
        }
        return copy
    }

    /// Returns a copy of `summary` with a speaker rename applied to its
    /// name-bearing fields: action-item owners and per-speaker highlight names.
    ///
    /// A summary stores display *names* (whatever the transcript carried when it
    /// was generated — "You"/"Them", a previous rename, or a bare id), not
    /// speaker ids. So `previousTranscript` must be the transcript as it was
    /// BEFORE applying `map`: it links each speaker id to its previous display
    /// name, letting old names be translated to the new ones. Renaming again
    /// later keeps working because the rewritten summary is saved each time.
    ///
    /// Only exact (trimmed) matches are rewritten — free prose (tldr, overview,
    /// task texts) is left untouched, and owners like "unassigned" pass through.
    /// If two ids somehow share one previous display name, the later mapping
    /// wins (degenerate input; harmless).
    public static func apply(
        _ map: SpeakerMap,
        toSummary summary: MeetingSummary,
        previousTranscript: Transcript
    ) -> MeetingSummary {
        // speaker id → the display name the summary would have used for it.
        var previousNames: [String: String] = [:]
        for utterance in previousTranscript.utterances
        where previousNames[utterance.speakerId] == nil {
            previousNames[utterance.speakerId] = utterance.speakerName ?? utterance.speakerId
        }

        // Old display name (and the bare id) → new name.
        var translation: [String: String] = [:]
        for (speakerId, newName) in map.names {
            translation[speakerId] = newName
            if let previous = previousNames[speakerId] {
                translation[previous] = newName
            }
        }

        func renamed(_ name: String) -> String {
            translation[name.trimmingCharacters(in: .whitespacesAndNewlines)] ?? name
        }

        var copy = summary
        copy.actionItems = summary.actionItems.map { item in
            var updated = item
            updated.owner = renamed(item.owner)
            return updated
        }
        copy.perSpeakerHighlights = summary.perSpeakerHighlights.map { highlight in
            var updated = highlight
            updated.speaker = renamed(highlight.speaker)
            return updated
        }
        return copy
    }

    /// Returns up to `perSpeaker` sample utterance texts for each speaker id.
    ///
    /// Speakers appear (as dictionary keys) in order of first appearance in
    /// the transcript; for each, the first `perSpeaker` utterance texts are
    /// collected in transcript order. A non-positive `perSpeaker` yields an
    /// empty list of samples for every speaker that occurs.
    public static func samples(
        from transcript: Transcript,
        perSpeaker: Int = 3
    ) -> [String: [String]] {
        let limit = max(0, perSpeaker)
        var samples: [String: [String]] = [:]
        for utterance in transcript.utterances {
            var existing = samples[utterance.speakerId] ?? []
            if existing.count < limit {
                existing.append(utterance.text)
            }
            samples[utterance.speakerId] = existing
        }
        return samples
    }
}
