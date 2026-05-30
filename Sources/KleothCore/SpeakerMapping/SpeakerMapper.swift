import Foundation

/// Applies a `SpeakerMap` to a transcript and extracts representative
/// samples per speaker (used to help a human assign real names).
public enum SpeakerMapper {
    /// Returns a copy of `transcript` with `speakerName` populated from `map`.
    public static func apply(_ map: SpeakerMap, to transcript: Transcript) -> Transcript {
        fatalError("unimplemented")
    }

    /// Returns up to `perSpeaker` sample utterance texts for each speaker id.
    public static func samples(
        from transcript: Transcript,
        perSpeaker: Int = 3
    ) -> [String: [String]] {
        fatalError("unimplemented")
    }
}
