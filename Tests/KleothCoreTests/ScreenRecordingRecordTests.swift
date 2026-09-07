import Testing
import Foundation
@testable import KleothCore

/// The transcript sidecar of a screen recording: the JSON shape the viewer
/// edits in place, the word-at-time lookup that drives the highlight, and the
/// pairing of a movie with its sidecar on disk.
@Suite struct ScreenRecordingRecordTests {
    private let words = [
        RecordingWord(text: "hello", start: 0.5, end: 0.9),
        RecordingWord(text: "there", start: 1.0, end: 1.4),
        RecordingWord(text: "world", start: 2.0, end: 2.6),
    ]

    @Test func sidecarRoundTripsThroughSnakeCase() throws {
        let record = ScreenRecordingRecord(
            title: "Demo", durationSecs: 12.5, languageCode: "ru",
            transcriptTier: TranscriptTier.local, transcriptModel: "large-v3",
            transcribedAt: Date(timeIntervalSince1970: 1_757_000_000), words: words)
        let data = try ScreenRecordingStore.encoder.encode(record)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"duration_secs\""))
        #expect(json.contains("\"transcript_tier\""))
        #expect(json.contains("\"schema_version\""))
        #expect(!json.contains("durationSecs"))
        let back = try ScreenRecordingStore.decoder.decode(ScreenRecordingRecord.self, from: data)
        #expect(back == record)
    }

    @Test func wordIndexFindsTheWordBeingSpoken() {
        let record = ScreenRecordingRecord(words: words)
        #expect(record.wordIndex(at: 0.0) == nil)
        #expect(record.wordIndex(at: 0.5) == 0)
        #expect(record.wordIndex(at: 0.95) == 0)   // gap → the last started word
        #expect(record.wordIndex(at: 1.2) == 1)
        #expect(record.wordIndex(at: 99) == 2)
        #expect(ScreenRecordingRecord().wordIndex(at: 1) == nil)
    }

    @Test func replacingWordEditsTrimsAndRemoves() {
        let record = ScreenRecordingRecord(words: words)
        #expect(record.replacingWord(at: 1, with: "  their ").words[1].text == "their")
        #expect(record.replacingWord(at: 1, with: "   ").words.map(\.text) == ["hello", "world"])
        #expect(record.replacingWord(at: 7, with: "x") == record)
    }

    @Test func wordsFromResponseKeepOnlyTimedWords() {
        let response = ScribeResponse(words: [
            ScribeWord(text: "b", start: 1.0, end: 1.2, type: "word"),
            ScribeWord(text: " ", start: 0.9, end: 1.0, type: "spacing"),
            ScribeWord(text: "(laughs)", start: 0.2, end: 0.4, type: "audio_event"),
            ScribeWord(text: "a", start: 0.1, end: 0.3),
            ScribeWord(text: "no-time", start: nil, end: nil, type: "word"),
        ])
        let words = ScreenRecordingRecord.words(from: response)
        #expect(words.map(\.text) == ["a", "b"])
    }

    @Test func transcriptStateFollowsTheSidecar() {
        let url = URL(fileURLWithPath: "/tmp/screen-2026-09-07-101010.mp4")
        #expect(ScreenRecordingItem(url: url, recordedAt: .now, sizeBytes: 1, record: nil).transcriptState == .untranscribed)
        #expect(ScreenRecordingItem(url: url, recordedAt: .now, sizeBytes: 1,
                                    record: ScreenRecordingRecord(transcriptError: "boom")).transcriptState == .failed("boom"))
        #expect(ScreenRecordingItem(url: url, recordedAt: .now, sizeBytes: 1,
                                    record: ScreenRecordingRecord(words: words)).transcriptState == .transcribed)
        #expect(ScreenRecordingItem(url: url, recordedAt: .now, sizeBytes: 1, record: nil).displayTitle == "screen-2026-09-07-101010")
    }

    @Test func namingPairsMovieAndSidecar() {
        let movie = URL(fileURLWithPath: "/x/screen-2026-09-07-101010-2.mp4")
        #expect(ScreenRecordingFileNaming.sidecarURL(for: movie).lastPathComponent == "screen-2026-09-07-101010-2.json")
        #expect(ScreenRecordingFileNaming.isFinishedRecordingName("screen-2026-09-07-101010.mp4"))
        #expect(ScreenRecordingFileNaming.isFinishedRecordingName("screen-2026-09-07-101010-recovered.mp4"))
        #expect(!ScreenRecordingFileNaming.isFinishedRecordingName("screen-2026-09-07-101010.recording.mp4"))
        #expect(!ScreenRecordingFileNaming.isFinishedRecordingName("screen-2026-09-07-101010.json"))

        let date = ScreenRecordingFileNaming.date(fromStemOf: movie)
        let expected = ScreenRecordingFileNaming.baseName(for: date!)
        #expect(expected == "screen-2026-09-07-101010")
        #expect(ScreenRecordingFileNaming.date(fromStemOf: URL(fileURLWithPath: "/x/other.mp4")) == nil)
    }

    @Test func storeListsMoviesWithTheirSidecars() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-rec-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let older = dir.appendingPathComponent("screen-2026-09-07-090000.mp4")
        let newer = dir.appendingPathComponent("screen-2026-09-07-100000.mp4")
        let inFlight = dir.appendingPathComponent("screen-2026-09-07-110000.recording.mp4")
        for url in [older, newer, inFlight] { try Data([0, 1, 2]).write(to: url) }
        try ScreenRecordingStore.saveRecord(ScreenRecordingRecord(title: "Old", words: words), for: older)

        let items = ScreenRecordingStore.listRecordings(in: dir)
        #expect(items.map(\.url.lastPathComponent) == [newer.lastPathComponent, older.lastPathComponent])
        #expect(items[0].record == nil)
        #expect(items[1].record?.title == "Old")
        #expect(items[1].sizeBytes == 3)
        #expect(ScreenRecordingStore.listRecordings(in: dir.appendingPathComponent("missing")).isEmpty)
    }
}
