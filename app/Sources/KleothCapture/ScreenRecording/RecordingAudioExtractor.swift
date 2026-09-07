import AVFoundation
import Foundation

/// Pulls the audio track out of a finished screen recording into an `.m4a`
/// the transcribers can read (and that is small enough to upload to Scribe —
/// the movie itself is tens of megabytes per minute).
///
/// `AVAssetExportPresetAppleM4A` does the whole job: it is audio-only by
/// definition (the video track is dropped, not transcoded) and re-encodes to
/// AAC in an `.m4a` container — the same shape `ChannelAudio` hands the
/// transcribers for meetings and dictations. A ~22 MB/min movie becomes a few
/// hundred KB per minute.
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
    ///
    /// - Throws: ``ExtractionError/noAudioTrack`` when the movie carries no
    ///   audio at all (a `--no-mic` recording of a silent machine still has an
    ///   audio track, so this really means a malformed or video-only file),
    ///   ``ExtractionError/exportFailed`` for everything else.
    public static func extractAudio(from movieURL: URL, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: movieURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw ExtractionError.noAudioTrack }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // The export refuses to overwrite, so a retry has to clear the way.
        try? fileManager.removeItem(at: outputURL)

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ExtractionError.exportFailed("no export session for \(movieURL.lastPathComponent)")
        }
        session.outputURL = outputURL
        session.outputFileType = .m4a
        try await run(session)
    }

    /// The pre-macOS-15 completion-handler export, wrapped in a continuation.
    ///
    /// `export(to:as:)` — the throwing async form that replaces all of this —
    /// is macOS 15+, and this package's floor is 14.4, so the deprecated trio
    /// (`exportAsynchronously` / `status` / `error`) is the only option. The
    /// deprecation is annotated rather than ignored so the warning comes back
    /// the day the floor moves.
    @available(macOS, deprecated: 15.0, message: "Replace with the async export(to:as:) once the floor is macOS 15.")
    private static func run(_ session: AVAssetExportSession) async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        switch session.status {
        case .completed:
            return
        case .cancelled:
            throw ExtractionError.exportFailed("cancelled")
        default:
            throw ExtractionError.exportFailed(
                session.error?.localizedDescription ?? "export status \(session.status.rawValue)"
            )
        }
    }
}
