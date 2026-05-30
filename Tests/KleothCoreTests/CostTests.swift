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

        let pipeline = MeetingPipeline(scribe: scribe, summarizer: nil, store: store)

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
}
