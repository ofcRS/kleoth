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
