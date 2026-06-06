import Testing
import Foundation
@testable import KleothCore

@Suite struct MeetingStoreRenameTests {
    /// A minimal saved meeting to rename: one-channel transcript + metadata.
    private func makeMeeting(
        in baseDir: URL,
        title: String,
        summary: MeetingSummary? = nil
    ) throws -> (store: MeetingStore, dir: URL) {
        let store = MeetingStore(baseDir: baseDir)
        let raw = ScribeResponse(
            transcripts: [
                ScribeChannelTranscript(
                    words: [ScribeWord(text: "Hello", start: 0, end: 1, type: "word")],
                    channelIndex: 0
                )
            ],
            audioDurationSecs: 1,
            languageCode: "en"
        )
        let transcript = TranscriptNormalizer.normalize(raw)
        let metadata = MeetingMetadata(title: title, date: "2026-06-05")
        let markdown = MarkdownRenderer.render(
            summary: summary,
            transcript: transcript,
            metadata: metadata,
            includeTranscript: true
        )
        let dir = MeetingStore.uniqueMeetingDirectory(in: baseDir)
        try store.save(
            in: dir,
            raw: raw,
            transcript: transcript,
            summary: summary,
            summaryMarkdown: markdown,
            speakerMap: nil,
            metadata: metadata
        )
        return (store, dir)
    }

    /// Renaming rewrites the title in `meta.json` (other fields intact) and
    /// re-renders `summary.md` so the user-owned Markdown header matches.
    @Test func renameRewritesMetadataAndMarkdown() throws {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-rename-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let (store, dir) = try makeMeeting(in: baseDir, title: "Meeting 2026-06-05")
        let updated = try store.renameMeeting(in: dir, to: "Quarterly Planning")

        #expect(updated.title == "Quarterly Planning")
        #expect(updated.date == "2026-06-05")  // every other field preserved

        let reloaded = try store.loadMetadata(in: dir)
        #expect(reloaded.title == "Quarterly Planning")

        let markdown = try String(
            contentsOf: dir.appendingPathComponent("summary.md"),
            encoding: .utf8
        )
        #expect(markdown.contains("Quarterly Planning"))
        #expect(!markdown.contains("Meeting 2026-06-05"))

        // The transcript artifacts survive the rename untouched.
        let transcript = try store.loadTranscript(in: dir)
        #expect(transcript.utterances.first?.text == "Hello")
    }

    /// Consecutive renames keep working (each starts from the saved state).
    @Test func renameTwiceKeepsLatestTitle() throws {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-rename-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let (store, dir) = try makeMeeting(in: baseDir, title: "Original")
        try store.renameMeeting(in: dir, to: "First Rename")
        try store.renameMeeting(in: dir, to: "Second Rename")

        #expect(try store.loadMetadata(in: dir).title == "Second Rename")
    }

    /// A meta-only folder (no transcript — e.g. failed processing) still renames:
    /// just `meta.json` is rewritten, and no Markdown appears from thin air.
    @Test func renameWithoutTranscriptUpdatesMetaOnly() throws {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-rename-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let dir = MeetingStore.uniqueMeetingDirectory(in: baseDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = MeetingStore.makeEncoder()
        let metadata = MeetingMetadata(title: "Recovered", date: "2026-06-05")
        try encoder.encode(metadata).write(to: dir.appendingPathComponent("meta.json"))

        let store = MeetingStore(baseDir: baseDir)
        try store.renameMeeting(in: dir, to: "Recovered, Renamed")

        #expect(try store.loadMetadata(in: dir).title == "Recovered, Renamed")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("summary.md").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.md").path))
    }
}
