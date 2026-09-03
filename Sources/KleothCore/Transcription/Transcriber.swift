import Foundation

/// An engine that turns an audio file into a raw `ScribeResponse` (single- or
/// multi-channel), which `MeetingPipeline` then normalizes, optionally
/// summarizes, renders, and stores.
///
/// This is the seam that lets the pipeline be independent of the transcription
/// backend: ElevenLabs Scribe (paid, SOTA, diarized) and on-device engines
/// (free) both conform, so the same normalize → summarize → render → store path
/// serves a free local default and a paid on-demand upgrade.
public protocol Transcriber: Sendable {
    /// USD billed per hour of audio by this engine. `0` for on-device engines.
    var usdPerHour: Double { get }

    /// Transcribes the audio at `fileURL`, returning a raw `ScribeResponse`.
    ///
    /// Engines that own their own per-channel inputs (e.g. an on-device engine
    /// fed `mic.m4a` and `system.m4a` separately) may ignore `fileURL` in favor
    /// of state captured at construction; `fileURL` remains the single-file
    /// fallback for imported audio.
    func transcribe(fileURL: URL, options: ScribeOptions) async throws -> ScribeResponse

    /// The engine/model name to record alongside a transcript produced with
    /// `options` (e.g. the dictation log's `transcription_model`). Scribe
    /// answers with the `model_id` it actually sends; the default names the
    /// conforming type, so an injected engine is never logged as Scribe.
    func modelIdentifier(for options: ScribeOptions) -> String
}

public extension Transcriber {
    func modelIdentifier(for options: ScribeOptions) -> String {
        String(describing: Self.self)
    }
}

// `ScribeClient`'s conformance lives in ScribeClient.swift: because `Transcriber`
// refines `Sendable`, the conformance must be declared in the same file as the
// type.
