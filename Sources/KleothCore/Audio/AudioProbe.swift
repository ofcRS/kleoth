import Foundation
import AVFoundation

/// Reads the wall-clock duration of an audio file.
///
/// This is the robust source of a meeting's duration: ElevenLabs Scribe's
/// multichannel response reports `audio_duration_secs` summed across channels
/// (≈2× the real elapsed time), so duration is derived from the audio file
/// itself rather than the STT response.
public enum AudioProbe {
    /// Wall-clock seconds of an audio file, or `nil` if it cannot be read.
    ///
    /// Opening or probing a non-audio / corrupt file throws; we map any such
    /// failure to `nil` so callers can fall back to another duration source
    /// instead of crashing.
    public static func durationSeconds(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return Double(file.length) / sampleRate
    }
}
