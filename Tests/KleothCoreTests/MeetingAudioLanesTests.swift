import Testing
import Foundation
@testable import KleothCore

/// Lane lengths are the real ones from three affected meetings (2026-11-17/18)
/// and one correct 48 kHz meeting, as `afinfo` reported them.
@Suite struct MeetingAudioLanesTests {
    /// A Bluetooth headset (16 kHz) beside the 48 kHz tap: 34m 48s of meeting,
    /// a `meeting.m4a` of 104m 24s.
    private let headset = MeetingAudioLanes(
        mic: .init(frames: 33_419_264, sampleRate: 16_000),       // 2088.704 s
        system: .init(frames: 100_220_416, sampleRate: 48_000)    // 2087.925 s
    )
    /// A MacBook's array (44.1 kHz).
    private let array = MeetingAudioLanes(
        mic: .init(frames: 91_794_150, sampleRate: 44_100),       // 2081.5 s
        system: .init(frames: 99_893_248, sampleRate: 48_000)     // 2081.109 s
    )
    /// Both lanes at 48 kHz: the combine was always right.
    private let sameRate = MeetingAudioLanes(
        mic: .init(frames: 1_366_032, sampleRate: 48_000),        // 28.459 s
        system: .init(frames: 1_428_992, sampleRate: 48_000)      // 29.771 s
    )

    @Test func expectedIsTheLongerLane() {
        #expect(abs(headset.expectedSeconds! - 2088.704) < 0.001)
        #expect(abs(array.expectedSeconds! - 2081.5) < 0.001)
        #expect(abs(sameRate.expectedSeconds! - 29.771) < 0.001)
        #expect(MeetingAudioLanes(mic: nil, system: nil).expectedSeconds == nil)
    }

    @Test func preFixLengthIsWhatTheOldCombineWrote() {
        // afinfo on the real meeting.m4a files: 6263.776 s and 2265.153016 s.
        #expect(abs(headset.preFixSeconds! - 6263.776) < 0.001)
        #expect(abs(array.preFixSeconds! - 2265.153016) < 0.001)
        #expect(sameRate.preFixSeconds == sameRate.expectedSeconds)
    }

    @Test func onlyTheOldCombinesFileIsRebuilt() {
        #expect(headset.combinedNeedsRebuild(combinedSeconds: 6263.776))
        #expect(array.combinedNeedsRebuild(combinedSeconds: 2265.153016))
        // A rebuilt (correct) file, give or take an AAC packet: left alone.
        #expect(!headset.combinedNeedsRebuild(combinedSeconds: 2088.704))
        #expect(!headset.combinedNeedsRebuild(combinedSeconds: 2088.75))
        #expect(!array.combinedNeedsRebuild(combinedSeconds: 2081.5))
        #expect(!sameRate.combinedNeedsRebuild(combinedSeconds: 29.770667))
        // Off from the lanes for some other reason: never touched.
        #expect(!headset.combinedNeedsRebuild(combinedSeconds: 1000))
    }

    /// A dead microphone lane (a header-only `mic.m4a`): the old combine took
    /// the system lane's rate, so its file was right.
    @Test func aSystemOnlyMeetingIsNeverRebuilt() {
        let lanes = MeetingAudioLanes(mic: nil, system: .init(frames: 23_490_048, sampleRate: 48_000))
        #expect(lanes.preFixSeconds == lanes.expectedSeconds)
        #expect(!lanes.combinedNeedsRebuild(combinedSeconds: 489.376))
    }

    /// A clip of a second or two: the stretch is still caught, AAC rounding is not.
    @Test func shortClipsUseTheQuarterSecondFloor() {
        let clip = MeetingAudioLanes(
            mic: .init(frames: 20_480, sampleRate: 16_000),       // 1.28 s
            system: .init(frames: 77_312, sampleRate: 48_000)     // 1.611 s
        )
        #expect(clip.combinedNeedsRebuild(combinedSeconds: 4.832))
        #expect(!clip.combinedNeedsRebuild(combinedSeconds: 1.611 + 0.064))
        #expect(!MeetingAudioLanes.differ(1.611, 1.675))
        #expect(MeetingAudioLanes.differ(100, 102))
        #expect(!MeetingAudioLanes.differ(100, 100.9))
    }

    /// meeting-2026-11-17-120145's real `meta.json` cost: a cloud transcript
    /// priced on the stretched 5979.616 s.
    @Test func correctedCostUsesTheRealLength() throws {
        let lanes = MeetingAudioLanes(
            mic: .init(frames: 31_883_264, sampleRate: 16_000),   // 1992.704 s
            system: .init(frames: 95_673_856, sampleRate: 48_000) // 1993.205 s
        )
        let stored = CostBreakdown(
            transcriptionUSD: 0.36542097777777777, summaryUSD: 0.00122059278, audioDurationSecs: 5979.616
        )
        let fixed = try #require(lanes.corrected(stored))
        #expect(abs(fixed.audioDurationSecs! - 1993.2053) < 0.001)
        // $0.22 an hour of the real length.
        #expect(abs(fixed.transcriptionUSD - 0.22 * 1993.2053 / 3600) < 0.000_01)
        #expect(fixed.summaryUSD == stored.summaryUSD)
        // Once corrected, nothing more to correct.
        #expect(lanes.corrected(fixed) == nil)
        // A free on-device transcript stays free.
        let local = try #require(lanes.corrected(CostBreakdown(audioDurationSecs: 5979.616)))
        #expect(local.transcriptionUSD == 0)
        // A stored length that is not the old combine's is left alone.
        #expect(lanes.corrected(CostBreakdown(audioDurationSecs: 1993.2)) == nil)
        #expect(lanes.corrected(CostBreakdown(audioDurationSecs: 3000)) == nil)
        #expect(lanes.corrected(CostBreakdown()) == nil)
    }
}

@Suite struct MeetingStoreAudioDurationTests {
    private let lanes = MeetingAudioLanes(
        mic: .init(frames: 31_883_264, sampleRate: 16_000),
        system: .init(frames: 95_673_856, sampleRate: 48_000)
    )

    private func makeMeeting() throws -> (MeetingStore, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-durations-\(UUID().uuidString)", isDirectory: true)
        let dir = base.appendingPathComponent("meeting-2026-11-17-120145", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (MeetingStore(baseDir: base), dir)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MeetingStore.makeEncoder().encode(value).write(to: url)
    }

    @Test func metaAndVariantCostsAreCorrectedOnce() throws {
        let (store, dir) = try makeMeeting()
        defer { try? FileManager.default.removeItem(at: store.baseDir) }
        let context = MeetingContext(startedFrom: "pill", appName: "Zoom", appBundleId: "us.zoom.xos", micSeconds: 1990)
        let metadata = MeetingMetadata(
            title: "Weekly sync", date: "2026-11-17", startedAt: "2026-11-17T12:01:45Z",
            participants: ["Anna"], consentAcknowledged: true, model: "z-ai/glm-5.3-flash",
            languageCode: "ru",
            cost: CostBreakdown(transcriptionUSD: 0.36542097777777777, summaryUSD: 0.0012, audioDurationSecs: 5979.616),
            transcriptTier: TranscriptTier.sotaScribe, summaryProvider: "openrouter", context: context
        )
        try write(metadata, to: dir.appendingPathComponent("meta.json"))
        let variant = dir.appendingPathComponent("variants/local-whisper/variant.json")
        try write(TranscriptVariantInfo(
            transcriptTier: TranscriptTier.local, cost: CostBreakdown(audioDurationSecs: 5979.616)
        ), to: variant)

        let folderDate = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: folderDate], ofItemAtPath: dir.path)

        #expect(store.storedAudioDurationsNeedingCorrection(in: dir, lanes: lanes).count == 2)
        let rewritten = try store.correctStoredAudioDurations(in: dir, lanes: lanes)
        #expect(rewritten.map(\.lastPathComponent) == ["meta.json", "variant.json"])
        // The folder keeps its date: History may order the meeting by it.
        let modified = try #require(
            try URL(fileURLWithPath: dir.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )
        #expect(abs(modified.timeIntervalSince(folderDate)) < 1)

        let fixed = try store.loadMetadata(in: dir)
        #expect(abs(fixed.cost!.audioDurationSecs! - 1993.2053) < 0.001)
        #expect(abs(fixed.cost!.transcriptionUSD - 0.1218) < 0.0001)
        // Everything else is as it was.
        #expect(fixed.title == "Weekly sync")
        #expect(fixed.participants == ["Anna"])
        #expect(fixed.model == "z-ai/glm-5.3-flash")
        #expect(fixed.summaryProvider == "openrouter")
        #expect(fixed.languageCode == "ru")
        #expect(fixed.cost!.summaryUSD == 0.0012)
        #expect(fixed.context == context)
        let info = try MeetingStore.makeDecoder().decode(TranscriptVariantInfo.self, from: Data(contentsOf: variant))
        #expect(abs(info.cost!.audioDurationSecs! - 1993.2053) < 0.001)

        // A second pass finds nothing and writes nothing.
        #expect(store.storedAudioDurationsNeedingCorrection(in: dir, lanes: lanes).isEmpty)
        let before = try Data(contentsOf: dir.appendingPathComponent("meta.json"))
        #expect(try store.correctStoredAudioDurations(in: dir, lanes: lanes).isEmpty)
        #expect(try Data(contentsOf: dir.appendingPathComponent("meta.json")) == before)
    }

    @Test func aMeetingWithoutCostIsLeftAlone() throws {
        let (store, dir) = try makeMeeting()
        defer { try? FileManager.default.removeItem(at: store.baseDir) }
        try write(MeetingMetadata(title: "Untranscribed", date: "2026-11-18"), to: dir.appendingPathComponent("meta.json"))
        #expect(store.storedAudioDurationsNeedingCorrection(in: dir, lanes: lanes).isEmpty)
        #expect(try store.correctStoredAudioDurations(in: dir, lanes: lanes).isEmpty)
    }
}
