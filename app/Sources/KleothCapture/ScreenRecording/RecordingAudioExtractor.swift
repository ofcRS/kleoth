import AVFoundation
import Foundation

/// Pulls the audio track out of a finished screen recording into an `.m4a`
/// the transcribers can read (and that is small enough to upload to Scribe —
/// the movie itself is tens of megabytes per minute).
///
/// Contract stub — lane L2 implements it with `AVAssetExportSession`
/// (`AVAssetExportPresetAppleM4A`, audio-only).
public enum RecordingAudioExtractor {
    public enum ExtractionError: Error, LocalizedError {
        case noAudioTrack
        case exportFailed(String)
        case notImplemented

        public var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "The recording has no audio track."
            case .exportFailed(let reason): return "Audio extraction failed: \(reason)"
            case .notImplemented: return "Audio extraction is not implemented yet."
            }
        }
    }

    /// Writes the movie's audio to `outputURL` (replacing any file there).
    public static func extractAudio(from movieURL: URL, to outputURL: URL) async throws {
        _ = movieURL
        _ = outputURL
        throw ExtractionError.notImplemented
    }
}
