import AVFoundation
import Foundation
import KleothCore
import Testing
@testable import KleothCapture

/// The repair for meetings combined by 0.5.7 or earlier (``MeetingAudioRepair``),
/// on synthetic meeting folders: lanes at their own rates and the
/// `meeting.m4a` the old combine made of them — both lanes' frames at the
/// microphone's rate.
@Suite struct MeetingAudioRepairTests {
    private struct Meeting {
        let base: URL
        let dir: URL
        var mic: URL { dir.appendingPathComponent("mic.m4a") }
        var system: URL { dir.appendingPathComponent("system.m4a") }
        var combined: URL { dir.appendingPathComponent("meeting.m4a") }
        var meta: URL { dir.appendingPathComponent("meta.json") }
    }

    private func writeTone(_ url: URL, sampleRate: Double, channels: Int, frames total: Int) throws {
        let format = try #require(AudioFormat.pcmFloat32(sampleRate: sampleRate, channels: channels))
        do {
            let file = try AudioFormat.openAACFile(at: url, sampleRate: sampleRate, channels: channels)
            var written = 0
            while written < total {
                let count = min(4096, total - written)
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
                buffer.frameLength = AVAudioFrameCount(count)
                let planes = try #require(buffer.floatChannelData)
                for frame in 0..<count {
                    let sample = Float(0.4 * sin(2 * .pi * 440 * Double(written + frame) / sampleRate))
                    for channel in 0..<channels { planes[channel][frame] = sample }
                }
                try file.write(from: buffer)
                written += count
            }
        }
    }

    private func seconds(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private func folderDate(_ dir: URL) throws -> Date {
        try #require(try URL(fileURLWithPath: dir.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }

    private func leftovers(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".meeting-rebuild-") }
    }

    /// A meeting folder with the two lanes and the old combine's file: the
    /// longer lane's frame count at the microphone's rate.
    private func makeMeeting(
        micRate: Double, micFrames: Int, systemFrames: Int, oldCombinedFile: Bool = true
    ) throws -> Meeting {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-repair-tests-\(UUID().uuidString)", isDirectory: true)
        let dir = base.appendingPathComponent("meeting-2000-01-02-030405", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meeting = Meeting(base: base, dir: dir)
        try writeTone(meeting.mic, sampleRate: micRate, channels: 1, frames: micFrames)
        try writeTone(meeting.system, sampleRate: 48_000, channels: 2, frames: systemFrames)
        if oldCombinedFile {
            try writeTone(meeting.combined, sampleRate: micRate, channels: 2, frames: max(micFrames, systemFrames))
        }
        return meeting
    }

    /// A 16 kHz headset: 4 s of microphone, 5 s of the other side, the old
    /// 15 s `meeting.m4a`, and a cloud transcript's `meta.json` priced on it.
    private func makeHeadsetMeeting() throws -> Meeting {
        let meeting = try makeMeeting(micRate: 16_000, micFrames: 64_000, systemFrames: 240_000)
        let stretched = try seconds(meeting.combined)
        let metadata = MeetingMetadata(
            title: "Weekly sync", date: "2000-01-02", startedAt: "2000-01-02T03:04:05Z",
            consentAcknowledged: true,
            cost: CostBreakdown(
                transcriptionUSD: TranscriptTier.scribeUSDPerHour * stretched / 3600, summaryUSD: 0.001,
                audioDurationSecs: stretched
            ),
            transcriptTier: TranscriptTier.sotaScribe
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try encoder.encode(metadata).write(to: meeting.meta)
        return meeting
    }

    @Test func theOldCombinesFileIsFound() throws {
        let meeting = try makeHeadsetMeeting()
        defer { try? FileManager.default.removeItem(at: meeting.base) }

        let inspection = try #require(MeetingAudioRepair.inspect(meeting.dir))
        #expect(abs(try #require(inspection.combinedSeconds) - 15) < 0.01)
        #expect(inspection.combinedSampleRate == 16_000)
        #expect(!inspection.combinedMarked)
        #expect(abs(try #require(inspection.lanes.expectedSeconds) - 5) < 0.01)
        #expect(inspection.combinedNeedsRebuild)
        #expect(inspection.storedDurationsToCorrect.map(\.lastPathComponent) == ["meta.json"])
        #expect(MeetingAudioRepair.triage(meeting.dir) == .needsRepair)
        #expect(MeetingAudioRepair.scan(meeting.base).needsRepair.map(\.lastPathComponent)
            == [meeting.dir.lastPathComponent])
    }

    @Test func rebuildReplacesOnlyTheCombinedFileOnce() throws {
        let meeting = try makeHeadsetMeeting()
        defer { try? FileManager.default.removeItem(at: meeting.base) }
        let micBytes = try Data(contentsOf: meeting.mic)
        let systemBytes = try Data(contentsOf: meeting.system)
        // A rebuild a kill left behind, and a folder date History may sort by.
        try Data("partial".utf8).write(to: meeting.dir.appendingPathComponent(".meeting-rebuild-left-by-a-kill.m4a"))
        let date = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: meeting.dir.path)

        let rebuild = try #require(try MeetingAudioRepair.rebuildCombinedFile(in: meeting.dir))

        #expect(abs(try #require(rebuild.before) - 15) < 0.01)
        #expect(abs(rebuild.after - 5) < 0.005)
        let file = try AVAudioFile(forReading: meeting.combined)
        #expect(file.processingFormat.sampleRate == 48_000)
        #expect(file.processingFormat.channelCount == 2)
        #expect(abs(try seconds(meeting.combined) - 5) < 0.005)
        #expect(MeetingAudioRepair.isMarkedResampled(meeting.combined))
        // The lanes are only read.
        #expect(try Data(contentsOf: meeting.mic) == micBytes)
        #expect(try Data(contentsOf: meeting.system) == systemBytes)
        // Nothing left beside it, and the folder keeps its date.
        #expect(try leftovers(meeting.dir).isEmpty)
        #expect(abs(try folderDate(meeting.dir).timeIntervalSince(date)) < 1)

        // A second run finds a correct file and leaves it alone.
        let rebuiltBytes = try Data(contentsOf: meeting.combined)
        #expect(try MeetingAudioRepair.rebuildCombinedFile(in: meeting.dir) == nil)
        #expect(try Data(contentsOf: meeting.combined) == rebuiltBytes)
    }

    /// A 44.1 kHz microphone lane with more frames than the 48 kHz other side:
    /// the old file lasted the right 5 s with the other side still too slow.
    /// The rate gives it away.
    @Test func anOldFileOfTheRightLengthIsRebuilt() throws {
        let meeting = try makeMeeting(micRate: 44_100, micFrames: 220_500, systemFrames: 192_000)
        defer { try? FileManager.default.removeItem(at: meeting.base) }
        #expect(abs(try seconds(meeting.combined) - 5) < 0.001)

        let inspection = try #require(MeetingAudioRepair.inspect(meeting.dir))
        #expect(inspection.combinedNeedsRebuild)
        #expect(inspection.storedDurationsToCorrect.isEmpty)
        let rebuild = try #require(try MeetingAudioRepair.rebuildCombinedFile(in: meeting.dir))
        #expect(abs(rebuild.after - 5) < 0.005)
        #expect(try AVAudioFile(forReading: meeting.combined).processingFormat.sampleRate == 48_000)
    }

    /// A `meeting.m4a` that is there but unreadable (a combine cut short) or
    /// empty, beside intact lanes: rebuilt.
    @Test(arguments: [Data((0..<4096).map { UInt8($0 % 251) }), Data()])
    func anUnreadableCombinedFileIsRebuilt(contents: Data) throws {
        let meeting = try makeMeeting(micRate: 16_000, micFrames: 32_000, systemFrames: 96_000, oldCombinedFile: false)
        defer { try? FileManager.default.removeItem(at: meeting.base) }
        try contents.write(to: meeting.combined)

        let inspection = try #require(MeetingAudioRepair.inspect(meeting.dir))
        #expect(inspection.combinedExists)
        #expect(inspection.combinedSeconds == nil)
        #expect(inspection.combinedNeedsRebuild)
        #expect(MeetingAudioRepair.triage(meeting.dir) == .needsRepair)

        let rebuild = try #require(try MeetingAudioRepair.rebuildCombinedFile(in: meeting.dir))
        #expect(rebuild.before == nil)
        #expect(abs(try seconds(meeting.combined) - 2) < 0.005)
    }

    /// A missing `meeting.m4a` is not this repair's (it is built when a
    /// transcription needs it).
    @Test func aMissingCombinedFileIsLeftToTheTranscription() throws {
        let meeting = try makeMeeting(micRate: 16_000, micFrames: 32_000, systemFrames: 96_000, oldCombinedFile: false)
        defer { try? FileManager.default.removeItem(at: meeting.base) }
        #expect(MeetingAudioRepair.inspect(meeting.dir)?.needsRepair == false)
        #expect(MeetingAudioRepair.triage(meeting.dir) == .fine)
        #expect(try MeetingAudioRepair.rebuildCombinedFile(in: meeting.dir) == nil)
        // The transcription path's safe write builds it.
        try MeetingAudioRepair.writeCombinedFile(in: meeting.dir)
        #expect(abs(try seconds(meeting.combined) - 2) < 0.005)
    }

    /// A rebuild that fails after its new file exists — the combine throws
    /// halfway, or the new file comes out the wrong length — keeps the old
    /// file, leaves nothing beside it, and the folder keeps its date.
    @Test(arguments: ["throws", "wrong length"])
    func aFailedRebuildKeepsTheOldFile(failure: String) throws {
        let meeting = try makeHeadsetMeeting()
        defer { try? FileManager.default.removeItem(at: meeting.base) }
        let oldBytes = try Data(contentsOf: meeting.combined)
        let date = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: meeting.dir.path)
        struct Halfway: Error {}

        #expect(throws: (any Error).self) {
            try MeetingAudioRepair.rebuildCombinedFile(in: meeting.dir) { _, _, temporary in
                if failure == "throws" {
                    try Data("half an m4a".utf8).write(to: temporary)
                    throw Halfway()
                }
                try writeTone(temporary, sampleRate: 48_000, channels: 2, frames: 48_000)   // 1 s, not 5
                return temporary
            }
        }

        #expect(try Data(contentsOf: meeting.combined) == oldBytes)
        #expect(try leftovers(meeting.dir).isEmpty)
        #expect(abs(try folderDate(meeting.dir).timeIntervalSince(date)) < 1)
        #expect(MeetingAudioRepair.inspect(meeting.dir)?.combinedNeedsRebuild == true)
    }

    /// The stored length goes with the audio; afterwards the folder is done,
    /// and a marked file is fine without opening a lane.
    @Test func storedDurationIsCorrectedAndTheMeetingDropsOut() throws {
        let meeting = try makeHeadsetMeeting()
        defer { try? FileManager.default.removeItem(at: meeting.base) }
        let inspection = try #require(MeetingAudioRepair.inspect(meeting.dir))

        _ = try MeetingAudioRepair.rebuildCombinedFile(in: meeting.dir)
        let store = MeetingStore(baseDir: meeting.base)
        let rewritten = try store.correctStoredAudioDurations(in: meeting.dir, lanes: inspection.lanes)

        #expect(rewritten.map(\.lastPathComponent) == ["meta.json"])
        let cost = try #require(try store.loadMetadata(in: meeting.dir).cost)
        #expect(abs(try #require(cost.audioDurationSecs) - 5) < 0.01)
        #expect(abs(cost.transcriptionUSD - TranscriptTier.scribeUSDPerHour * 5 / 3600) < 0.000_001)
        #expect(cost.summaryUSD == 0.001)
        #expect(MeetingAudioRepair.inspect(meeting.dir)?.needsRepair == false)
        #expect(MeetingAudioRepair.scan(meeting.base, deep: true).needsRepair.isEmpty)

        // The mark alone decides: even a lane gone bad is not opened.
        try Data("not audio".utf8).write(to: meeting.mic)
        #expect(MeetingAudioRepair.triage(meeting.dir) == .fine)
    }

    /// Both lanes at 48 kHz: the old combine was right, nothing is touched.
    @Test func aCorrectMeetingIsLeftAlone() throws {
        let meeting = try makeMeeting(micRate: 48_000, micFrames: 96_000, systemFrames: 120_000)
        defer { try? FileManager.default.removeItem(at: meeting.base) }
        let bytes = try Data(contentsOf: meeting.combined)

        #expect(MeetingAudioRepair.inspect(meeting.dir)?.needsRepair == false)
        #expect(MeetingAudioRepair.scan(meeting.base).needsRepair.isEmpty)
        #expect(try MeetingAudioRepair.rebuildCombinedFile(in: meeting.dir) == nil)
        #expect(try Data(contentsOf: meeting.combined) == bytes)
    }

    @Test func aLocalFileIsDownloaded() throws {
        let meeting = try makeMeeting(micRate: 48_000, micFrames: 4_800, systemFrames: 4_800)
        defer { try? FileManager.default.removeItem(at: meeting.base) }
        #expect(!MeetingAudioRepair.isNotDownloaded(meeting.mic))
        #expect(!MeetingAudioRepair.isNotDownloaded(meeting.dir.appendingPathComponent("absent.m4a")))
    }
}
