import Testing
import Foundation
@testable import KleothCore

/// What a pipeline run records about its summary
/// (docs/plans/2026-09-24-summary-truncation-and-onboarding-skip.md §3.3, §4.1):
/// `meta.json` names a model and a provider only when that run wrote a summary.
/// Callers stamp both before the run, so without this a meeting whose summary
/// failed would still name the model that produced nothing.
@Suite struct MeetingPipelineSummaryTests {
    // MARK: - Fixtures

    /// An answer with every key the prompt asks for.
    static let completeAnswer =
        #"{"title":"T","tldr":"t","overview":"o","action_items":[],"per_speaker_highlights":[]}"#

    /// What one pipeline run left behind.
    struct Outcome {
        let summary: MeetingSummary?
        let summaryError: String?
        /// The saved `meta.json`, read back from disk.
        let meta: MeetingMetadata
        let meetingDir: URL

        func hasFile(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: meetingDir.appendingPathComponent(name).path)
        }
    }

    /// A fresh folder for one test's store and audio; the test removes it.
    static func scratchDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-pipeline-summary-\(UUID().uuidString)", isDirectory: true)
    }

    /// Runs the pipeline on a canned transcript into a store under `baseDir`,
    /// with the metadata stamped the way callers stamp it before a run:
    /// model "m", provider "openrouter".
    static func run(summarizer: Summarizer?, summarize: Bool = true, in baseDir: URL) async throws -> Outcome {
        let transcriber = CannedTranscriber(response: ScribeResponse(
            words: [ScribeWord(text: "Hello", start: 0, end: 0.5, type: "word", speakerId: "speaker_0")],
            audioDurationSecs: 60
        ))
        let store = MeetingStore(baseDir: baseDir)
        let pipeline = MeetingPipeline(transcriber: transcriber, summarizer: summarizer, store: store)

        // Any bytes do: `AudioProbe` can't read them, so the duration falls
        // back to the transcript's.
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let audioFile = baseDir.appendingPathComponent("audio.m4a")
        try Data("fake-audio".utf8).write(to: audioFile)

        let result = try await pipeline.run(
            audioFile: audioFile,
            metadata: MeetingMetadata(title: "Launch", date: "2026-09-24", model: "m", summaryProvider: "openrouter"),
            options: ScribeOptions(),
            summarize: summarize
        )
        return Outcome(
            summary: result.summary,
            summaryError: result.summaryError,
            meta: try store.loadMetadata(in: result.meetingDir),
            meetingDir: result.meetingDir
        )
    }

    // MARK: - Provenance

    @Test func failedSummaryDropsProvenance() async throws {
        let baseDir = Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let failing = Summarizer(client: MockChatClient(results: [
            .failure(OpenRouterError.httpError(status: 500, bodySnippet: "x")),
        ]))

        let run = try await Self.run(summarizer: failing, in: baseDir)

        #expect(run.summary == nil)
        #expect(run.summaryError != nil)
        #expect(!run.hasFile("summary.json"))
        #expect(run.hasFile("transcript.json"))  // the transcript is saved as always
        #expect(run.meta.model == nil)
        #expect(run.meta.summaryProvider == nil)
        #expect(run.meta.title == "Launch")  // only the provenance goes
    }

    /// No provider resolved, so the run doesn't summarize. A re-transcription
    /// passes the meeting's saved metadata, provenance of its earlier summary
    /// included — that summary is archived, so the new root must not name it.
    @Test func skippedSummaryDropsProvenance() async throws {
        let baseDir = Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let run = try await Self.run(summarizer: nil, summarize: false, in: baseDir)

        #expect(run.summary == nil)
        #expect(run.summaryError == nil)
        #expect(!run.hasFile("summary.json"))
        #expect(run.meta.model == nil)
        #expect(run.meta.summaryProvider == nil)
    }

    /// Lock: a summary keeps the model and provider that wrote it.
    @Test func successfulSummaryKeepsProvenance() async throws {
        let baseDir = Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let answering = Summarizer(client: MockChatClient(results: [
            .success(ChatCompletion(content: Self.completeAnswer, finishReason: "stop")),
        ]))

        let run = try await Self.run(summarizer: answering, in: baseDir)

        #expect(run.summary != nil)
        #expect(run.summaryError == nil)
        #expect(run.hasFile("summary.json"))
        #expect(run.meta.model == "m")
        #expect(run.meta.summaryProvider == "openrouter")
    }
}

/// Returns a canned response instead of transcribing, and bills nothing.
private struct CannedTranscriber: Transcriber {
    let response: ScribeResponse
    var usdPerHour: Double { 0 }
    func transcribe(fileURL: URL, options: ScribeOptions) async throws -> ScribeResponse {
        response
    }
}
