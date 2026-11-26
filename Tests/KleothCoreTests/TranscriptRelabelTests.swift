import Foundation
import Testing
@testable import KleothCore

/// Re-attributing a stored cloud transcript from its lanes (the `relabel`
/// probe): the pure step, and the store's backup and write.
@Suite struct TranscriptRelabelTests {
    typealias Lanes = ChannelAttributionTests.Lanes

    /// A stored transcript as the per-cluster mapping left it: one remote voice
    /// on the system lane, labelled You throughout; the user's turn labelled You.
    private func oldMeeting() -> (raw: ScribeResponse, lanes: Lanes) {
        var lanes = Lanes(seconds: 30)
        lanes.micSpeech(2, 6)
        lanes.systemSpeech(10, 20)
        var words = ChannelAttributionTests.words("speaker_0", 2, 6)
        words += ChannelAttributionTests.words("speaker_0", 10, 20)
        let raw = ScribeResponse(text: "x", words: words, audioDurationSecs: 30, languageCode: "en")
        return (raw, lanes)
    }

    @Test func movesTheRemoteWordsAndKeepsNoClusterItNeverHad() throws {
        let (raw, lanes) = oldMeeting()
        let outcome = try TranscriptRelabel.relabel(
            raw, micEnergy: lanes.micEnergy, systemEnergy: lanes.systemEnergy, hopSeconds: Lanes.hop).get()
        let early = ChannelAttributionTests.words("speaker_0", 2, 6).count
        #expect(outcome.youBefore == raw.words!.count)
        #expect(outcome.youAfter == early)
        #expect(outcome.changed == raw.words!.count - early)
        #expect(!outcome.usedScribeClusters)
        // The old label is not Scribe's cluster: it is never recorded as one.
        #expect(outcome.response.words!.allSatisfy { $0.diarizedSpeakerId == nil })
        #expect(outcome.response.words!.map(\.text) == raw.words!.map(\.text))
        #expect(outcome.response.languageCode == "en")
    }

    @Test func refusesPerLaneTranscriptsAndUntimedOnes() {
        let multichannel = ScribeResponse(transcripts: [ScribeChannelTranscript(words: [], channelIndex: 0)])
        #expect(TranscriptRelabel.relabel(multichannel, micEnergy: [1], systemEnergy: [1], hopSeconds: 0.05)
            .failureValue == .perLaneTranscript)
        let untimed = ScribeResponse(words: [ScribeWord(text: "x", type: "word", speakerId: "speaker_0")])
        #expect(TranscriptRelabel.relabel(untimed, micEnergy: [1], systemEnergy: [1], hopSeconds: 0.05)
            .failureValue == .noWords)
    }

    // MARK: - The store

    private func savedMeeting(summary: MeetingSummary?) throws -> (store: MeetingStore, dir: URL, raw: ScribeResponse, lanes: Lanes) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-relabel-\(UUID().uuidString)", isDirectory: true)
        let store = MeetingStore(baseDir: base)
        let (raw, lanes) = oldMeeting()
        let map = SpeakerMap(names: ["speaker_0": "You", "speaker_1": "Them"])
        let metadata = MeetingMetadata(title: "Planning", date: "2026-11-01", transcriptTier: TranscriptTier.sotaScribe)
        let transcript = SpeakerMapper.apply(map, to: TranscriptNormalizer.normalize(raw))
        let dir = MeetingStore.uniqueMeetingDirectory(in: base)
        try store.save(
            in: dir, raw: raw, transcript: transcript, summary: summary,
            summaryMarkdown: summary.map { MarkdownRenderer.render(summary: $0, transcript: transcript, metadata: metadata, includeTranscript: true) },
            speakerMap: map, metadata: metadata)
        return (store, dir, raw, lanes)
    }

    @Test func replacingKeepsTheFirstTranscriptAndRedrawsTheMarkdown() throws {
        let (store, dir, raw, lanes) = try savedMeeting(summary: MeetingSummary(tldr: "Short.", overview: "Longer."))
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let original = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        let meta = try Data(contentsOf: dir.appendingPathComponent("meta.json"))
        let summaryJSON = try Data(contentsOf: dir.appendingPathComponent("summary.json"))
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: dir.path)
        #expect(!(try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)).contains("Them:"))

        let source = try store.relabelSource(in: dir)
        #expect(!source.fromBackup)
        let outcome = try TranscriptRelabel.relabel(
            source.raw, micEnergy: lanes.micEnergy, systemEnergy: lanes.systemEnergy, hopSeconds: Lanes.hop).get()
        try store.replaceRawTranscript(in: dir, with: outcome.response)

        let backup = dir.appendingPathComponent(MeetingStore.relabelBackupName)
        #expect(try Data(contentsOf: backup) == original)
        #expect(try Data(contentsOf: dir.appendingPathComponent("meta.json")) == meta)
        #expect(try Data(contentsOf: dir.appendingPathComponent("summary.json")) == summaryJSON)
        let lines = try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
        #expect(lines.hasPrefix("You: "))
        #expect(lines.contains("\nThem: "))
        #expect(try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8).contains("Them"))
        #expect(try store.loadTranscript(in: dir).utterances.map(\.speakerName) == ["You", "Them"])
        let modified = try dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(modified == stamp)

        // A second run starts from the backup and never overwrites it.
        let again = try store.relabelSource(in: dir)
        #expect(again.fromBackup)
        #expect(again.raw.words!.map(\.speakerId) == raw.words!.map(\.speakerId))
        try store.replaceRawTranscript(in: dir, with: again.raw)
        #expect(try Data(contentsOf: backup) == original)
    }

    @Test func aMeetingWithoutASummaryGetsNoSummaryMarkdown() throws {
        let (store, dir, _, lanes) = try savedMeeting(summary: nil)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let source = try store.relabelSource(in: dir)
        let outcome = try TranscriptRelabel.relabel(
            source.raw, micEnergy: lanes.micEnergy, systemEnergy: lanes.systemEnergy, hopSeconds: Lanes.hop).get()
        try store.replaceRawTranscript(in: dir, with: outcome.response)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("summary.md").path))
    }

    /// A backup left from an earlier transcript of the meeting is the user's
    /// file: re-labelling refuses rather than mix two transcripts.
    @Test func aBackupOfOtherWordsIsRefused() throws {
        let (store, dir, _, _) = try savedMeeting(summary: nil)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let other = ScribeResponse(words: [ScribeWord(text: "other", start: 1, end: 2, type: "word", speakerId: "speaker_0")])
        try MeetingStore.encodeRawTranscript(other).write(to: dir.appendingPathComponent(MeetingStore.relabelBackupName))
        #expect(throws: MeetingStoreError.staleRelabelBackup) { try store.relabelSource(in: dir) }
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
