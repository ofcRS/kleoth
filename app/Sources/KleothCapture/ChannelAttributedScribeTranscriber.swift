import Foundation
import KleothCore

/// The validated mono-Scribe transcriber: mixes the two captured channels
/// (`mic.m4a` = You, `system.m4a` = Them) down to one mono track, sends that to
/// ElevenLabs Scribe (single channel → 1× cost, correct duration), then
/// attributes each transcribed word to `speaker_0` (You) or `speaker_1` (Them)
/// by which channel was louder at the word's timestamp.
///
/// Scribe's own diarization is deliberately disabled — it scored only 61.8% on
/// this task; channel-energy attribution is both cheaper and more accurate when
/// each speaker already has a dedicated channel.
///
/// Conforms to ``Transcriber`` so `MeetingPipeline` (normalize → summarize →
/// render → store) is unchanged. Because `Transcriber` refines `Sendable`, the
/// conformance is declared here in the same file as the type.
public struct ChannelAttributedScribeTranscriber: Transcriber {
    /// Underlying Scribe client used for the single mono request.
    let scribe: ScribeClient
    /// You channel (microphone) → `speaker_0`.
    let micURL: URL
    /// Them channel (system audio) → `speaker_1`.
    let systemURL: URL
    /// Audio represented by each energy-envelope sample, in seconds.
    var hopSeconds: Double = 0.05

    public init(
        scribe: ScribeClient,
        micURL: URL,
        systemURL: URL,
        hopSeconds: Double = 0.05
    ) {
        self.scribe = scribe
        self.micURL = micURL
        self.systemURL = systemURL
        self.hopSeconds = hopSeconds
    }

    /// Billed at the underlying Scribe per-hour rate (a single mono request).
    public var usdPerHour: Double { scribe.usdPerHour }

    /// Mixes mic+system to mono, transcribes that single channel with Scribe, and
    /// re-attributes each word to You/Them by per-channel energy.
    ///
    /// `fileURL` is ignored — like `LocalTranscriber`, this engine owns its
    /// per-channel inputs (`micURL`, `systemURL`) captured at construction.
    public func transcribe(fileURL: URL, options: ScribeOptions) async throws -> ScribeResponse {
        // 1. Mix the two channels down to a temporary mono file (cleaned up after).
        let tempMono = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-mono-\(UUID().uuidString).m4a")
        _ = try ChannelAudio.mixToMono(channel0: micURL, channel1: systemURL, outputURL: tempMono)
        defer { try? FileManager.default.removeItem(at: tempMono) }

        // 2. Single-channel request: no multi-channel, no diarization, and no
        //    speaker-count hint — we attribute speakers ourselves from channel
        //    energy, so any caller-supplied numSpeakers would be contradictory.
        var opt = options
        opt.useMultiChannel = false
        opt.diarize = false
        opt.numSpeakers = nil
        let resp = try await scribe.transcribe(fileURL: tempMono, options: opt)

        // 3. Per-channel energy envelopes (mic → speaker_0, system → speaker_1).
        let e0 = try ChannelAudio.envelope(of: micURL, hopSeconds: hopSeconds)
        let e1 = try ChannelAudio.envelope(of: systemURL, hopSeconds: hopSeconds)

        // 4. Re-attribute each word to whichever channel was louder over its span.
        let words = ChannelAttribution.assignSpeakers(
            words: resp.words ?? [],
            channel0Energy: e0,
            channel1Energy: e1,
            hopSeconds: hopSeconds
        )

        // 5. Single-channel response shape carrying the attributed words. Duration
        //    is the (correct, single-channel) value Scribe returned for the mono
        //    file; the pipeline ultimately prefers AudioProbe on the meeting audio.
        return ScribeResponse(
            text: resp.text,
            words: words,
            transcripts: nil,
            audioDurationSecs: resp.audioDurationSecs,
            languageCode: resp.languageCode,
            transcriptionId: resp.transcriptionId
        )
    }
}
