import Testing
import Foundation
@testable import KleothCore

/// Turn order in an on-device two-channel meeting: mic = speaker_0 (You),
/// system audio = speaker_1 (Them), each channel transcribed on its own. A
/// short reply leaves only a short pause on the other channel, so the
/// 1.5 s silence rule alone can't split the turns around it; an on-device
/// (`local-whisper`) transcript also splits a turn where the other channel
/// said something inside the pause. Scribe transcripts keep their grouping.
@Suite struct TranscriptTurnTests {
    /// From the fictional quick-sync meeting as the on-device engine timed it:
    /// Them's "Sure." sits inside a 1.42 s pause in You's channel.
    static func quickExchange(reply: ScribeWord = ScribeWord(text: "Sure.", start: 3.24, end: 3.68, type: "word")) -> ScribeResponse {
        ScribeResponse(
            transcripts: [
                ScribeChannelTranscript(
                    words: [
                        ScribeWord(text: "Hey Marco, do you have a minute?", start: 0.02, end: 2.80, type: "word"),
                        ScribeWord(text: "Great, the build is green.", start: 4.22, end: 8.36, type: "word"),
                    ],
                    channelIndex: 0
                ),
                ScribeChannelTranscript(words: [reply], channelIndex: 1),
            ],
            audioDurationSecs: 9,
            languageCode: "en"
        )
    }

    private func turns(_ transcript: Transcript) -> [String] {
        transcript.utterances.map { "\($0.speakerId): \($0.text)" }
    }

    // MARK: - Normalizer

    @Test func onDeviceTurnSplitsWhereTheOtherSpeakerRepliedInThePause() {
        let transcript = TranscriptNormalizer.normalize(Self.quickExchange(), tier: TranscriptTier.local)

        #expect(turns(transcript) == [
            "speaker_0: Hey Marco, do you have a minute?",
            "speaker_1: Sure.",
            "speaker_0: Great, the build is green.",
        ])
        #expect(transcript.utterances.map(\.start) == [0.02, 3.24, 4.22])
        #expect(transcript.utterances.map(\.end) == [2.80, 3.68, 8.36])
    }

    @Test func scribeTranscriptKeepsItsGroupingAroundAReplyInAPause() {
        let expected = [
            "speaker_0: Hey Marco, do you have a minute? Great, the build is green.",
            "speaker_1: Sure.",
        ]
        let scribe = TranscriptNormalizer.normalize(Self.quickExchange(), tier: TranscriptTier.sotaScribe)
        let unknown = TranscriptNormalizer.normalize(Self.quickExchange())

        #expect(turns(scribe) == expected)
        #expect(turns(unknown) == expected)
    }

    /// Real WhisperKit output (speech runs, `localtranscribe`) of a fictional
    /// two-person call voiced by `say`, 0.2 s between turns, with one- and
    /// two-word replies ("Sure.", "Okay.", "No problem.", "Bye."): the
    /// transcript reads in the order the script was spoken.
    @Test func onDeviceQuickExchangeReadsInTheOrderItWasSpoken() throws {
        let raw = try Fixtures.scribeResponse("whisperkit_quick_exchange")
        let transcript = TranscriptNormalizer.normalize(raw, tier: TranscriptTier.local)

        // The script: fourteen lines, You first, strictly alternating.
        let script = [
            "Hey", "Sure", "Great", "Okay", "The", "Yes", "I",
            "Perfect", "Then", "Thursday", "One", "No", "Thanks", "Bye",
        ]
        #expect(transcript.utterances.map(\.speakerId)
            == (0..<14).map { $0.isMultiple(of: 2) ? "speaker_0" : "speaker_1" })
        #expect(transcript.utterances.map { String($0.text.prefix { $0.isLetter }) } == script)
    }

    @Test func onDeviceTurnIsNotSplitBySpeechThatOverlapsIt() {
        // Them starts talking before You pause (crosstalk, or the mic picking
        // up the other side): nothing was said *inside* the pause.
        let overlapping = ScribeWord(text: "Yeah.", start: 2.60, end: 3.00, type: "word")
        let transcript = TranscriptNormalizer.normalize(
            Self.quickExchange(reply: overlapping), tier: TranscriptTier.local)

        #expect(turns(transcript) == [
            "speaker_0: Hey Marco, do you have a minute? Great, the build is green.",
            "speaker_1: Yeah.",
        ])
    }

    // MARK: - Where transcripts are normalized

    private func scratchDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-turns-\(UUID().uuidString)", isDirectory: true)
    }

    /// `loadTranscript` (History, re-summarize) reads the tier from meta.json.
    @Test func loadTranscriptSplitsTurnsOfAnOnDeviceMeetingOnly() throws {
        let baseDir = scratchDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let store = MeetingStore(baseDir: baseDir)
        let raw = Self.quickExchange()

        func saved(tier: String) throws -> URL {
            let dir = baseDir.appendingPathComponent("meeting-\(tier)", isDirectory: true)
            try store.save(
                in: dir,
                raw: raw,
                transcript: TranscriptNormalizer.normalize(raw),
                summary: nil,
                summaryMarkdown: nil,
                speakerMap: nil,
                metadata: MeetingMetadata(title: "Sync", date: "2026-09-25", transcriptTier: tier)
            )
            return dir
        }

        let local = try store.loadTranscript(in: saved(tier: TranscriptTier.local))
        let scribe = try store.loadTranscript(in: saved(tier: TranscriptTier.sotaScribe))

        #expect(local.utterances.map(\.speakerId) == ["speaker_0", "speaker_1", "speaker_0"])
        #expect(scribe.utterances.map(\.speakerId) == ["speaker_0", "speaker_1"])
    }

    /// A pipeline run normalizes by the tier its caller stamped on the metadata.
    @Test func pipelineSplitsTurnsOfAnOnDeviceRun() async throws {
        let baseDir = scratchDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let audioFile = baseDir.appendingPathComponent("audio.m4a")
        try Data("fake-audio".utf8).write(to: audioFile)
        let pipeline = MeetingPipeline(
            transcriber: CannedTurnsTranscriber(response: Self.quickExchange()),
            summarizer: nil,
            store: MeetingStore(baseDir: baseDir)
        )

        let result = try await pipeline.run(
            audioFile: audioFile,
            metadata: MeetingMetadata(title: "Sync", date: "2026-09-25", transcriptTier: TranscriptTier.local),
            options: ScribeOptions(),
            summarize: false
        )

        #expect(result.transcript.utterances.map(\.speakerId) == ["speaker_0", "speaker_1", "speaker_0"])
        let markdown = try String(contentsOf: result.meetingDir.appendingPathComponent("transcript.md"), encoding: .utf8)
        #expect(markdown.contains("Sure."))
        #expect(!markdown.contains("minute? Great"))
    }

    /// Switching the active transcript back to the on-device one re-renders
    /// the root Markdown with its turns split.
    @Test func activatingTheOnDeviceVariantSplitsItsTurns() throws {
        let baseDir = scratchDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let store = MeetingStore(baseDir: baseDir)
        let dir = baseDir.appendingPathComponent("meeting-2026-09-25-140000", isDirectory: true)

        func save(_ raw: ScribeResponse, tier: String) throws {
            try store.save(
                in: dir,
                raw: raw,
                transcript: TranscriptNormalizer.normalize(raw, tier: tier),
                summary: nil,
                summaryMarkdown: nil,
                speakerMap: nil,
                metadata: MeetingMetadata(title: "Sync", date: "2026-09-25", transcriptTier: tier)
            )
        }
        try save(Self.quickExchange(), tier: TranscriptTier.local)
        try store.archiveActiveVariant(in: dir)
        let cloud = ScribeResponse(words: [
            ScribeWord(text: "Cloud", start: 0, end: 1, type: "word", speakerId: "speaker_0"),
        ])
        try save(cloud, tier: TranscriptTier.sotaScribe)

        try store.activateVariant(TranscriptTier.local, in: dir)

        let markdown = try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
        #expect(markdown.contains("Sure."))
        #expect(!markdown.contains("minute? Great"))
    }
}

/// Returns a canned response instead of transcribing, and bills nothing.
private struct CannedTurnsTranscriber: Transcriber {
    let response: ScribeResponse
    var usdPerHour: Double { 0 }
    func transcribe(fileURL: URL, options: ScribeOptions) async throws -> ScribeResponse {
        response
    }
}
