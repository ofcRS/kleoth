import Foundation
import KleothCore

/// The mono-Scribe transcriber: mixes the two captured channels
/// (`mic.m4a` = You, `system.m4a` = Them) down to one mono track, sends that to
/// ElevenLabs Scribe with diarization on (single channel → 1× cost, correct
/// duration), then decides each WORD's speaker, `speaker_0` (You) or
/// `speaker_1` (Them), by which lane carries a voice over that word
/// (``ChannelAttribution/attribute(words:micEnergy:systemEnergy:hopSeconds:youId:themId:)``).
///
/// Scribe's voice clusters are kept as the prior for words the lanes can't
/// decide, and recorded in each word's `diarizedSpeakerId`. Until 0.5.9 one
/// decision was made per cluster and the most mic-leaning cluster was always
/// You, so a silent mic still gave a remote voice the user's name.
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
    /// attributes each word to You/Them by the lanes' energy over it.
    ///
    /// `fileURL` is ignored — like `LocalTranscriber`, this engine owns its
    /// per-channel inputs (`micURL`, `systemURL`) captured at construction.
    public func transcribe(fileURL: URL, options: ScribeOptions) async throws -> ScribeResponse {
        // 1. Mix the two channels down to a temporary mono file (cleaned up after).
        let tempMono = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-mono-\(UUID().uuidString).m4a")
        _ = try ChannelAudio.mixToMono(channel0: micURL, channel1: systemURL, outputURL: tempMono)
        defer { try? FileManager.default.removeItem(at: tempMono) }

        // 2. Per-channel energy envelopes (mic → speaker_0, system → speaker_1),
        //    BEFORE the paid request: a lane that fails to read must not throw
        //    away a transcript already paid for.
        let e0 = try ChannelAudio.envelope(of: micURL, hopSeconds: hopSeconds)
        let e1 = try ChannelAudio.envelope(of: systemURL, hopSeconds: hopSeconds)

        // 3. Single-channel request with diarization on: Scribe clusters the
        //    words into distinct voices. numSpeakers is left unset — Scribe
        //    auto-detects; its clusters are the prior in step 4.
        var opt = options
        opt.useMultiChannel = false
        opt.diarize = true
        opt.numSpeakers = nil
        let resp = try await scribe.transcribe(fileURL: tempMono, options: opt)

        // 4. Each word to You/Them by the lane carrying a voice over it, Scribe's
        //    cluster as the prior (and kept in `diarizedSpeakerId`). An unreadable
        //    lane has an empty envelope: every word then goes to the other one.
        let words = ChannelAttribution.attribute(
            words: resp.words ?? [], micEnergy: e0, systemEnergy: e1, hopSeconds: hopSeconds
        ).words

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
