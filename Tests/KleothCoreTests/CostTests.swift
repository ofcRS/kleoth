import Testing
import Foundation
@testable import KleothCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite struct CostTests {
    /// ElevenLabs Scribe pricing used throughout: USD 0.22 per hour of audio.
    static let usdPerHour = 0.22

    /// The transcription-cost formula the pipeline applies.
    private func transcriptionUSD(forSeconds secs: Double) -> Double {
        Self.usdPerHour * secs / 3600
    }

    // MARK: - Rate math

    @Test func oneHourCostsExactlyTheHourlyRate() {
        // 3600 s -> 0.22
        #expect(abs(transcriptionUSD(forSeconds: 3600) - 0.22) < 1e-9)
    }

    @Test func halfHourCostsHalfTheHourlyRate() {
        #expect(abs(transcriptionUSD(forSeconds: 1800) - 0.11) < 1e-9)
    }

    @Test func zeroDurationCostsNothing() {
        #expect(abs(transcriptionUSD(forSeconds: 0)) < 1e-12)
    }

    @Test func costBreakdownTotalsTranscriptionPlusSummary() {
        let cost = CostBreakdown(
            transcriptionUSD: transcriptionUSD(forSeconds: 3600),
            summaryUSD: 0.05,
            audioDurationSecs: 3600
        )
        #expect(abs(cost.transcriptionUSD - 0.22) < 1e-9)
        #expect(abs(cost.totalUSD - 0.27) < 1e-9)
        #expect(cost.audioDurationSecs == 3600)
    }

    // MARK: - End-to-end through the pipeline (uses the real private rate)

    @Test func pipelineComputesTranscriptionCostFromAudioDuration() async throws {
        // A canned Scribe response: one hour of audio, single utterance.
        let scribeJSON = """
        {
          "language_code": "en",
          "audio_duration_secs": 3600,
          "transcription_id": "txn_cost_test",
          "words": [
            { "text": "Hello", "start": 0.0, "end": 0.5, "type": "word", "speaker_id": "speaker_0" }
          ]
        }
        """
        let transport = MockTransport(
            json: scribeJSON,
            url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
        )
        let scribe = ScribeClient(apiKey: "test-key", transport: transport)

        // Temp store so nothing leaks outside the test sandbox.
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-cost-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let store = MeetingStore(baseDir: baseDir)

        let pipeline = MeetingPipeline(transcriber: scribe, summarizer: nil, store: store)

        // An on-disk file is required to build the multipart upload body.
        let audioFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-cost-\(UUID().uuidString).m4a")
        try Data("fake-audio".utf8).write(to: audioFile)
        defer { try? FileManager.default.removeItem(at: audioFile) }

        let metadata = MeetingMetadata(title: "Cost Test", date: "2026-05-30")
        let result = try await pipeline.run(
            audioFile: audioFile,
            metadata: metadata,
            options: ScribeOptions(),
            summarize: false
        )

        #expect(result.cost.audioDurationSecs == 3600)
        #expect(abs(result.cost.transcriptionUSD - 0.22) < 1e-9)
        #expect(abs(result.cost.summaryUSD) < 1e-12)
        #expect(abs(result.cost.totalUSD - 0.22) < 1e-9)
    }

    // MARK: - Serialization round-trip (regression: acronym keys broke snake_case)

    @Test func costBreakdownRoundTripsThroughStoreCodec() throws {
        let original = CostBreakdown(transcriptionUSD: 0.22, summaryUSD: 0.0123, audioDurationSecs: 92.0)
        let data = try MeetingStore.makeEncoder().encode(original)
        let decoded = try MeetingStore.makeDecoder().decode(CostBreakdown.self, from: data)
        #expect(abs(decoded.transcriptionUSD - 0.22) < 1e-9)
        #expect(abs(decoded.summaryUSD - 0.0123) < 1e-9)
        #expect(decoded.audioDurationSecs == 92.0)
    }

    @Test func meetingMetadataWithCostRoundTripsThroughStoreCodec() throws {
        let meta = MeetingMetadata(
            title: "Sync",
            date: "2026-05-31",
            participants: ["Alex", "Sam"],
            consentAcknowledged: true,
            model: "openai/gpt-4.1-mini",
            languageCode: "en",
            cost: CostBreakdown(transcriptionUSD: 0.10, summaryUSD: 0.20, audioDurationSecs: 60)
        )
        let data = try MeetingStore.makeEncoder().encode(meta)
        let decoded = try MeetingStore.makeDecoder().decode(MeetingMetadata.self, from: data)
        #expect(decoded.cost != nil)
        #expect(abs((decoded.cost?.transcriptionUSD ?? 0) - 0.10) < 1e-9)
        #expect(abs((decoded.cost?.summaryUSD ?? 0) - 0.20) < 1e-9)
        #expect(abs((decoded.cost?.totalUSD ?? 0) - 0.30) < 1e-9)
        #expect(decoded.consentAcknowledged == true)
    }

    // MARK: - Per-engine cost (on-device local == free)

    @Test func localEngineTranscriptionCostsNothing() async throws {
        // A zero-cost (on-device) engine returns an hour of audio but bills $0.
        let response = ScribeResponse(
            words: [ScribeWord(text: "Hello", start: 0, end: 0.5, type: "word", speakerId: "speaker_0")],
            audioDurationSecs: 3600
        )
        let transcriber = ZeroCostTranscriber(response: response)

        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-local-cost-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let store = MeetingStore(baseDir: baseDir)
        let pipeline = MeetingPipeline(transcriber: transcriber, summarizer: nil, store: store)

        let audioFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-local-\(UUID().uuidString).m4a")
        try Data("fake-audio".utf8).write(to: audioFile)
        defer { try? FileManager.default.removeItem(at: audioFile) }

        let result = try await pipeline.run(
            audioFile: audioFile,
            metadata: MeetingMetadata(title: "Local", date: "2026-05-31"),
            options: ScribeOptions(),
            summarize: false
        )

        // Duration is still recorded, but the transcription itself is free.
        #expect(result.cost.audioDurationSecs == 3600)
        #expect(abs(result.cost.transcriptionUSD) < 1e-12)
        #expect(abs(result.cost.totalUSD) < 1e-12)
    }

    // MARK: - transcript_tier round-trip

    @Test func transcriptTierRoundTripsThroughStoreCodec() throws {
        let meta = MeetingMetadata(
            title: "Tiered",
            date: "2026-05-31",
            transcriptTier: TranscriptTier.local
        )
        let data = try MeetingStore.makeEncoder().encode(meta)
        // On disk the key must be acronym-free snake_case to round-trip.
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("transcript_tier"))

        let decoded = try MeetingStore.makeDecoder().decode(MeetingMetadata.self, from: data)
        #expect(decoded.transcriptTier == TranscriptTier.local)
        #expect(TranscriptTier.isSOTA(decoded.transcriptTier) == false)
        #expect(TranscriptTier.isSOTA(TranscriptTier.sotaScribe) == true)
    }
}

/// A trivial on-device-style transcriber for cost tests: returns a canned
/// response and bills nothing (`usdPerHour == 0`).
private struct ZeroCostTranscriber: Transcriber {
    let response: ScribeResponse
    var usdPerHour: Double { 0 }
    func transcribe(fileURL: URL, options: ScribeOptions) async throws -> ScribeResponse {
        response
    }
}
