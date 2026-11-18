import Testing
import Foundation
@testable import KleothCore

/// Synthetic lane lengths shaped like the affected meetings: a 16 kHz headset
/// or a 44.1 kHz MacBook array beside a 48 kHz system lane.
@Suite struct MeetingAudioLanesTests {
    /// A Bluetooth headset (16 kHz): 100 s of microphone, 100.25 s of the other side.
    private let headset = MeetingAudioLanes(
        mic: .init(frames: 1_600_000, sampleRate: 16_000),
        system: .init(frames: 4_812_000, sampleRate: 48_000)
    )
    /// A MacBook's array (44.1 kHz): 100 s of microphone, 99.75 s of the other side.
    private let array = MeetingAudioLanes(
        mic: .init(frames: 4_410_000, sampleRate: 44_100),
        system: .init(frames: 4_788_000, sampleRate: 48_000)
    )
    /// The array again, with the other side's lane much shorter (80 s): the
    /// microphone has more frames, so the old file lasted the right 100 s.
    private let arrayLongMic = MeetingAudioLanes(
        mic: .init(frames: 4_410_000, sampleRate: 44_100),
        system: .init(frames: 3_840_000, sampleRate: 48_000)
    )
    /// Both lanes at 48 kHz: the combine was always right.
    private let sameRate = MeetingAudioLanes(
        mic: .init(frames: 1_440_000, sampleRate: 48_000),
        system: .init(frames: 1_500_000, sampleRate: 48_000)
    )

    @Test func expectedIsTheLongerLaneAtTheHigherRate() {
        #expect(headset.expectedSeconds == 100.25)
        #expect(array.expectedSeconds == 100)
        #expect(sameRate.expectedSeconds == 31.25)
        #expect(headset.highestSampleRate == 48_000)
        #expect(MeetingAudioLanes(mic: nil, system: nil).expectedSeconds == nil)
        #expect(MeetingAudioLanes(mic: .init(frames: 16_000, sampleRate: 16_000), system: nil).highestSampleRate == 16_000)
    }

    @Test func preFixLengthIsWhatTheOldCombineWrote() {
        // The longer lane's frames at the microphone's rate.
        #expect(headset.preFixSeconds == 300.75)
        #expect(abs(array.preFixSeconds! - 108.5714) < 0.001)
        #expect(arrayLongMic.preFixSeconds == arrayLongMic.expectedSeconds)
        #expect(sameRate.preFixSeconds == sameRate.expectedSeconds)
    }

    /// The old combine wrote at the microphone's rate, the new one at the
    /// higher lane's: a file below it is the old one.
    @Test func aFileBelowTheHigherRateIsRebuilt() {
        #expect(headset.combinedNeedsRebuild(combinedSampleRate: 16_000, resampled: false))
        #expect(array.combinedNeedsRebuild(combinedSampleRate: 44_100, resampled: false))
        #expect(!headset.combinedNeedsRebuild(combinedSampleRate: 48_000, resampled: false))
        #expect(!sameRate.combinedNeedsRebuild(combinedSampleRate: 48_000, resampled: false))
        // A marked file is the new combine's, whatever else.
        #expect(!headset.combinedNeedsRebuild(combinedSampleRate: 16_000, resampled: true))
    }

    /// Right length, wrong speed: the length alone cannot tell, the rate can.
    @Test func anOldFileOfTheRightLengthIsStillRebuilt() {
        #expect(arrayLongMic.preFixSeconds == arrayLongMic.expectedSeconds)
        #expect(arrayLongMic.combinedNeedsRebuild(combinedSampleRate: 44_100, resampled: false))
    }

    /// A microphone above the system lane's rate: both combines write the
    /// microphone's rate, so only the mark tells the new file from the old.
    @Test func aMicrophoneAboveTheSystemRateIsToldByTheMark() {
        let lanes = MeetingAudioLanes(
            mic: .init(frames: 4_800_000, sampleRate: 48_000),
            system: .init(frames: 4_410_000, sampleRate: 44_100)
        )
        #expect(lanes.highestSampleRate == 48_000)
        #expect(lanes.combinedNeedsRebuild(combinedSampleRate: 48_000, resampled: false))
        #expect(!lanes.combinedNeedsRebuild(combinedSampleRate: 48_000, resampled: true))
    }

    /// A dead microphone lane (a header-only `mic.m4a`): the old combine took
    /// the system lane's rate, so its file was right.
    @Test func aSystemOnlyMeetingIsNeverRebuilt() {
        let lanes = MeetingAudioLanes(mic: nil, system: .init(frames: 4_800_000, sampleRate: 48_000))
        #expect(lanes.preFixSeconds == lanes.expectedSeconds)
        #expect(!lanes.combinedNeedsRebuild(combinedSampleRate: 48_000, resampled: false))
    }

    @Test func durationsDifferPastOnePercentAndAQuarterSecond() {
        #expect(!MeetingAudioLanes.differ(1.611, 1.675))
        #expect(MeetingAudioLanes.differ(1.611, 4.832))
        #expect(MeetingAudioLanes.differ(100, 102))
        #expect(!MeetingAudioLanes.differ(100, 100.9))
    }

    /// A cloud transcript's cost priced on the stretched 300.75 s.
    @Test func correctedCostUsesTheRealLength() throws {
        let rate = TranscriptTier.scribeUSDPerHour
        let stored = CostBreakdown(transcriptionUSD: rate * 300.75 / 3600, summaryUSD: 0.001, audioDurationSecs: 300.75)
        let fixed = try #require(headset.corrected(stored))
        #expect(fixed.audioDurationSecs == 100.25)
        #expect(abs(fixed.transcriptionUSD - rate * 100.25 / 3600) < 0.000_000_1)
        #expect(fixed.summaryUSD == stored.summaryUSD)
        // Once corrected, nothing more to correct.
        #expect(headset.corrected(fixed) == nil)
        // A free on-device transcript stays free.
        let local = try #require(headset.corrected(CostBreakdown(audioDurationSecs: 300.75)))
        #expect(local.transcriptionUSD == 0)
        // A stored length that is not the old combine's is left alone.
        #expect(headset.corrected(CostBreakdown(audioDurationSecs: 100.2)) == nil)
        #expect(headset.corrected(CostBreakdown(audioDurationSecs: 200)) == nil)
        #expect(headset.corrected(CostBreakdown()) == nil)
        // The right-length old file stored the right length.
        #expect(arrayLongMic.corrected(CostBreakdown(audioDurationSecs: 100)) == nil)
    }
}

@Suite struct MeetingAudioRepairStateTests {
    private let all = ["meeting-a", "meeting-b", "meeting-c", "meeting-d"]

    @Test func theFirstPassLooksAtEveryMeetingButTheFailed() {
        #expect(MeetingAudioRepairState().foldersToCheck(all: all) == all)
        #expect(MeetingAudioRepairState(failed: ["meeting-b"]).foldersToCheck(all: all)
            == ["meeting-a", "meeting-c", "meeting-d"])
    }

    @Test func afterAPassOnlyThePendingOnes() {
        let state = MeetingAudioRepairState(
            completedPass: MeetingAudioRepairState.currentPass,
            pending: ["meeting-c", "meeting-gone"], failed: ["meeting-b"]
        )
        #expect(state.foldersToCheck(all: all) == ["meeting-c"])
        #expect(MeetingAudioRepairState(completedPass: MeetingAudioRepairState.currentPass)
            .foldersToCheck(all: all).isEmpty)
    }

    /// A pass from an older version of the repair scans everything once more.
    @Test func anOlderPassScansAgain() {
        let state = MeetingAudioRepairState(completedPass: MeetingAudioRepairState.currentPass - 1)
        #expect(state.foldersToCheck(all: all) == all)
    }

    @Test func roundTripsThroughJSON() throws {
        let state = MeetingAudioRepairState(completedPass: 1, pending: ["meeting-c"], failed: ["meeting-b"])
        let data = try JSONEncoder().encode(["/tmp/x": state])
        #expect(try JSONDecoder().decode([String: MeetingAudioRepairState].self, from: data)["/tmp/x"] == state)
    }
}

@Suite struct MeetingStoreAudioDurationTests {
    private let lanes = MeetingAudioLanes(
        mic: .init(frames: 1_600_000, sampleRate: 16_000),
        system: .init(frames: 4_812_000, sampleRate: 48_000)
    )

    private func makeMeeting() throws -> (MeetingStore, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-durations-\(UUID().uuidString)", isDirectory: true)
        let dir = base.appendingPathComponent("meeting-2000-01-02-030405", isDirectory: true)
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
        let rate = TranscriptTier.scribeUSDPerHour
        let context = MeetingContext(startedFrom: "pill", appName: "Zoom", appBundleId: "us.zoom.xos", micSeconds: 98)
        let metadata = MeetingMetadata(
            title: "Weekly sync", date: "2000-01-02", startedAt: "2000-01-02T03:04:05Z",
            participants: ["Anna"], consentAcknowledged: true, model: "z-ai/glm-5.3-flash",
            languageCode: "ru",
            cost: CostBreakdown(transcriptionUSD: rate * 300.75 / 3600, summaryUSD: 0.0012, audioDurationSecs: 300.75),
            transcriptTier: TranscriptTier.sotaScribe, summaryProvider: "openrouter", context: context
        )
        try write(metadata, to: dir.appendingPathComponent("meta.json"))
        let variant = dir.appendingPathComponent("variants/local-whisper/variant.json")
        try write(TranscriptVariantInfo(
            transcriptTier: TranscriptTier.local, cost: CostBreakdown(audioDurationSecs: 300.75)
        ), to: variant)
        let folderDate = Date(timeIntervalSince1970: 1_000_000_000)
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
        #expect(fixed.cost!.audioDurationSecs == 100.25)
        #expect(abs(fixed.cost!.transcriptionUSD - rate * 100.25 / 3600) < 0.000_000_1)
        // Everything else is as it was.
        #expect(fixed.title == "Weekly sync")
        #expect(fixed.participants == ["Anna"])
        #expect(fixed.model == "z-ai/glm-5.3-flash")
        #expect(fixed.summaryProvider == "openrouter")
        #expect(fixed.languageCode == "ru")
        #expect(fixed.cost!.summaryUSD == 0.0012)
        #expect(fixed.context == context)
        let info = try MeetingStore.makeDecoder().decode(TranscriptVariantInfo.self, from: Data(contentsOf: variant))
        #expect(info.cost!.audioDurationSecs == 100.25)

        // A second pass finds nothing and writes nothing.
        #expect(store.storedAudioDurationsNeedingCorrection(in: dir, lanes: lanes).isEmpty)
        let before = try Data(contentsOf: dir.appendingPathComponent("meta.json"))
        #expect(try store.correctStoredAudioDurations(in: dir, lanes: lanes).isEmpty)
        #expect(try Data(contentsOf: dir.appendingPathComponent("meta.json")) == before)
    }

    @Test func aMeetingWithoutCostIsLeftAlone() throws {
        let (store, dir) = try makeMeeting()
        defer { try? FileManager.default.removeItem(at: store.baseDir) }
        try write(MeetingMetadata(title: "Untranscribed", date: "2000-01-02"), to: dir.appendingPathComponent("meta.json"))
        #expect(store.storedAudioDurationsNeedingCorrection(in: dir, lanes: lanes).isEmpty)
        #expect(try store.correctStoredAudioDurations(in: dir, lanes: lanes).isEmpty)
    }
}
