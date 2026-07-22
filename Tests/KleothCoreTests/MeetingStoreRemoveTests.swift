import Testing
import Foundation
@testable import KleothCore

@Suite struct MeetingStoreRemoveTests {
    private func makeBaseDir() -> URL {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-remove-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        return baseDir
    }

    /// Saves a fully transcribed meeting into `dir`: the four root artifacts,
    /// a speaker map, meta.json carrying every identity + transcript-derived
    /// field, and placeholder audio files alongside.
    @discardableResult
    private func saveTranscribedMeeting(store: MeetingStore, dir: URL) throws -> MeetingMetadata {
        let raw = ScribeResponse(
            transcripts: [
                ScribeChannelTranscript(
                    words: [ScribeWord(text: "Words", start: 0, end: 1, type: "word")],
                    channelIndex: 0
                )
            ],
            audioDurationSecs: 60,
            languageCode: "ru"
        )
        let transcript = TranscriptNormalizer.normalize(raw)
        let metadata = MeetingMetadata(
            title: "Weekly Sync",
            date: "2026-06-05",
            startedAt: "2026-06-05T12:00:00Z",
            participants: ["Anna", "Boris"],
            consentAcknowledged: true,
            model: "google/gemini-3-flash-preview",
            languageCode: "ru",
            cost: CostBreakdown(transcriptionUSD: 0.22, summaryUSD: 0.02, audioDurationSecs: 60),
            transcriptTier: TranscriptTier.sotaScribe
        )
        let summary = MeetingSummary(tldr: "Tldr.")
        let markdown = MarkdownRenderer.render(
            summary: summary,
            transcript: transcript,
            metadata: metadata,
            includeTranscript: true
        )
        try store.save(
            in: dir,
            raw: raw,
            transcript: transcript,
            summary: summary,
            summaryMarkdown: markdown,
            speakerMap: SpeakerMap(names: ["speaker_0": "Anna", "speaker_1": "Them"]),
            metadata: metadata
        )
        for audio in ["mic.m4a", "system.m4a", "meeting.m4a"] {
            try Data("audio".utf8).write(to: dir.appendingPathComponent(audio))
        }
        return metadata
    }

    private func exists(_ name: String, in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    /// Removal deletes exactly the four root artifacts (and variants/), keeping
    /// the audio, speakers.json, and meta.json.
    @Test func removesArtifactsKeepsAudioSpeakersAndMeta() throws {
        let baseDir = makeBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let store = MeetingStore(baseDir: baseDir)
        let dir = MeetingStore.uniqueMeetingDirectory(in: baseDir)
        try saveTranscribedMeeting(store: store, dir: dir)

        try store.removeTranscription(in: dir, trash: false)

        for artifact in ["transcript.json", "transcript.md", "summary.json", "summary.md"] {
            #expect(!exists(artifact, in: dir))
        }
        for kept in ["mic.m4a", "system.m4a", "meeting.m4a", "speakers.json", "meta.json"] {
            #expect(exists(kept, in: dir))
        }
        #expect(store.loadSpeakerMap(in: dir)?.names["speaker_0"] == "Anna")
    }

    /// meta.json keeps the identity fields but drops every transcript-derived
    /// one — asserted through the snake_case loadMetadata round-trip.
    @Test func metaKeepsIdentityStripsTranscriptFields() throws {
        let baseDir = makeBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let store = MeetingStore(baseDir: baseDir)
        let dir = MeetingStore.uniqueMeetingDirectory(in: baseDir)
        try saveTranscribedMeeting(store: store, dir: dir)

        try store.removeTranscription(in: dir, trash: false)

        let metadata = try store.loadMetadata(in: dir)
        #expect(metadata.title == "Weekly Sync")
        #expect(metadata.date == "2026-06-05")
        #expect(metadata.startedAt == "2026-06-05T12:00:00Z")
        #expect(metadata.participants == ["Anna", "Boris"])
        #expect(metadata.consentAcknowledged)
        #expect(metadata.transcriptTier == nil)
        #expect(metadata.model == nil)
        #expect(metadata.languageCode == nil)
        #expect(metadata.cost == nil)
    }

    /// A second call on an already-reverted folder is a clean no-op.
    @Test func secondCallIsNoOp() throws {
        let baseDir = makeBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let store = MeetingStore(baseDir: baseDir)
        let dir = MeetingStore.uniqueMeetingDirectory(in: baseDir)
        try saveTranscribedMeeting(store: store, dir: dir)

        try store.removeTranscription(in: dir, trash: false)
        try store.removeTranscription(in: dir, trash: false)

        #expect(!exists("transcript.json", in: dir))
        let metadata = try store.loadMetadata(in: dir)
        #expect(metadata.title == "Weekly Sync")
        #expect(metadata.transcriptTier == nil)
    }

    /// An audio-only folder (no meta.json, never transcribed) no-ops cleanly.
    @Test func audioOnlyFolderNoOps() throws {
        let baseDir = makeBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let store = MeetingStore(baseDir: baseDir)
        let dir = baseDir.appendingPathComponent("meeting-audio-only", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: dir.appendingPathComponent("mic.m4a"))

        try store.removeTranscription(in: dir, trash: false)

        #expect(exists("mic.m4a", in: dir))
        #expect(!exists("meta.json", in: dir))
    }

    /// Archived variants are removed wholesale — a reverted meeting reports
    /// zero available tiers.
    @Test func removesArchivedVariants() throws {
        let baseDir = makeBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let store = MeetingStore(baseDir: baseDir)
        let dir = MeetingStore.uniqueMeetingDirectory(in: baseDir)
        try saveTranscribedMeeting(store: store, dir: dir)
        try store.archiveActiveVariant(in: dir)
        try saveTranscribedMeeting(store: store, dir: dir)
        #expect(!store.availableVariantTiers(in: dir).isEmpty)

        try store.removeTranscription(in: dir, trash: false)

        #expect(!exists("variants", in: dir))
        #expect(store.availableVariantTiers(in: dir) == [])
    }
}
