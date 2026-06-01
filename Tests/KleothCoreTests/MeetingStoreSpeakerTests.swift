import Testing
import Foundation
@testable import KleothCore

@Suite struct MeetingStoreSpeakerTests {
    /// A raw 2-channel Scribe response: channel 0 / channel 1 normalize to
    /// `speaker_0` / `speaker_1` (no names of their own).
    private func twoChannelResponse() -> ScribeResponse {
        ScribeResponse(
            transcripts: [
                ScribeChannelTranscript(
                    words: [ScribeWord(text: "Hello", start: 0, end: 1, type: "word")],
                    channelIndex: 0
                ),
                ScribeChannelTranscript(
                    words: [ScribeWord(text: "Hi", start: 1.5, end: 2.5, type: "word")],
                    channelIndex: 1
                ),
            ],
            audioDurationSecs: 2.5,
            languageCode: "en"
        )
    }

    /// Saving a 2-channel transcript alongside a You/Them `speakers.json`, then
    /// loading via `loadTranscript`, applies the names — the single chokepoint
    /// that keeps labels intact on re-summarize/redisplay.
    @Test func loadTranscriptAppliesSpeakersJson() throws {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-speaker-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let store = MeetingStore(baseDir: baseDir)

        let raw = twoChannelResponse()
        let transcript = TranscriptNormalizer.normalize(raw)
        let map = SpeakerMap(names: ["speaker_0": "You", "speaker_1": "Them"])

        let dir = MeetingStore.uniqueMeetingDirectory(in: baseDir)
        try store.save(
            in: dir,
            raw: raw,
            transcript: transcript,
            summary: nil,
            summaryMarkdown: nil,
            speakerMap: map,
            metadata: MeetingMetadata(title: "Sync", date: "2026-06-01")
        )

        let loaded = try store.loadTranscript(in: dir)

        // Each utterance now carries its mapped display name.
        for utterance in loaded.utterances {
            switch utterance.speakerId {
            case "speaker_0": #expect(utterance.speakerName == "You")
            case "speaker_1": #expect(utterance.speakerName == "Them")
            default: Issue.record("Unexpected speaker \(utterance.speakerId)")
            }
        }
        let names = Set(loaded.utterances.compactMap(\.speakerName))
        #expect(names == ["You", "Them"])
    }

    /// With no `speakers.json`, `loadTranscript` returns bare ids (no names).
    @Test func loadTranscriptWithoutSpeakersJsonLeavesNamesNil() throws {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-speaker-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let store = MeetingStore(baseDir: baseDir)

        let raw = twoChannelResponse()
        let transcript = TranscriptNormalizer.normalize(raw)

        let dir = MeetingStore.uniqueMeetingDirectory(in: baseDir)
        try store.save(
            in: dir,
            raw: raw,
            transcript: transcript,
            summary: nil,
            summaryMarkdown: nil,
            speakerMap: nil,
            metadata: MeetingMetadata(title: "Sync", date: "2026-06-01")
        )

        let loaded = try store.loadTranscript(in: dir)
        #expect(loaded.utterances.allSatisfy { $0.speakerName == nil })
        #expect(store.loadSpeakerMap(in: dir) == nil)
    }
}
