import Foundation

/// Converts a raw `ScribeResponse` (single- or multi-channel) into a
/// normalized, speaker-grouped `Transcript`.
public enum TranscriptNormalizer {
    /// Groups Scribe words into utterances per speaker / channel.
    public static func normalize(_ response: ScribeResponse) -> Transcript {
        fatalError("unimplemented")
    }
}
