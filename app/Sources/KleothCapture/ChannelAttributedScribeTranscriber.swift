import Foundation
import KleothCore

/// The mono-Scribe transcriber: mixes the two captured channels
/// (`mic.m4a` = You, `system.m4a` = Them) down to one mono track, sends that to
/// ElevenLabs Scribe with diarization on (single channel → 1× cost, correct
/// duration), then maps each diarization *cluster* to `speaker_0` (You) or
/// `speaker_1` (Them) by which channel that cluster's speech lands on.
///
/// Scribe groups words into voices well, but its labels are arbitrary and it
/// can't know which voice is the mic user. So we keep Scribe's clustering (whole
/// turns stay together) and use per-cluster channel energy only to decide which
/// cluster is You — two robust decisions instead of one flaky guess per word. If
/// diarization comes back flat (0–1 clusters), we fall back to the per-word
/// energy split so speakers never collapse onto one side.
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

        // 2. Single-channel request with diarization on: Scribe clusters the
        //    words into distinct voices. numSpeakers is left unset — Scribe
        //    auto-detects, and we fold however many clusters it finds onto the
        //    two physical channels in step 4.
        var opt = options
        opt.useMultiChannel = false
        opt.diarize = true
        opt.numSpeakers = nil
        let resp = try await scribe.transcribe(fileURL: tempMono, options: opt)

        // 3. Per-channel energy envelopes (mic → speaker_0, system → speaker_1).
        let e0 = try ChannelAudio.envelope(of: micURL, hopSeconds: hopSeconds)
        let e1 = try ChannelAudio.envelope(of: systemURL, hopSeconds: hopSeconds)

        // 4. Map Scribe's voice clusters to You/Them by per-cluster channel
        //    energy (so whole turns stay together). If diarization came back flat
        //    (<2 clusters), fall back to the per-word energy split.
        let scribeWords = resp.words ?? []
        let clusterCount = Set(scribeWords.compactMap(\.speakerId)).count
        let words: [ScribeWord] = clusterCount >= 2
            ? ChannelAttribution.mapDiarizedSpeakers(
                words: scribeWords, channel0Energy: e0, channel1Energy: e1, hopSeconds: hopSeconds)
            : ChannelAttribution.assignSpeakers(
                words: scribeWords, channel0Energy: e0, channel1Energy: e1, hopSeconds: hopSeconds)

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
