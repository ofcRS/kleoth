import AVFoundation
import Foundation
import KleothCore
import Testing
@testable import KleothCapture

/// The repair for meetings combined by 0.5.7 or earlier (``MeetingAudioRepair``), on
/// a synthetic meeting folder: a 16 kHz `mic.m4a`, a 48 kHz `system.m4a`, and
/// the `meeting.m4a` the old combine made of them — both lanes' frames at
/// 16 kHz, three times the meeting.
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

    /// A meeting recorded with a 16 kHz headset: 4 s of microphone, 5 s of the
    /// other side, the old 15 s `meeting.m4a`, and a cloud transcript's
    /// `meta.json` priced on those 15 s.
    private func makeAffectedMeeting() throws -> Meeting {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-repair-tests-\(UUID().uuidString)", isDirectory: true)
        let dir = base.appendingPathComponent("meeting-2026-11-17-120145", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meeting = Meeting(base: base, dir: dir)
        try writeTone(meeting.mic, sampleRate: 16_000, channels: 1, frames: 64_000)
        try writeTone(meeting.system, sampleRate: 48_000, channels: 2, frames: 240_000)
        // What the old combine wrote: the longer lane's 240 000 frames at the
        // microphone's 16 kHz.
        try writeTone(meeting.combined, sampleRate: 16_000, channels: 2, frames: 240_000)

        let stretched = try seconds(meeting.combined)
        let metadata = MeetingMetadata(
            title: "Weekly sync", date: "2026-11-17", startedAt: "2026-11-17T12:01:45Z",
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
        let meeting = try makeAffectedMeeting()
        defer { try? FileManager.default.removeItem(at: meeting.base) }

        let inspection = try #require(MeetingAudioRepair.inspect(meeting.dir))
        #expect(abs(try #require(inspection.combinedSeconds) - 15) < 0.01)
        #expect(abs(try #require(inspection.lanes.expectedSeconds) - 5) < 0.01)
        #expect(inspection.combinedNeedsRebuild)
        #expect(inspection.storedDurationsToCorrect.map(\.lastPathComponent) == ["meta.json"])
        #expect(MeetingAudioRepair.meetingsNeedingRepair(in: meeting.base).map(\.lastPathComponent)
            == [meeting.dir.lastPathComponent])
    }

    @Test func rebuildReplacesOnlyTheCombinedFileOnce() throws {
        let meeting = try makeAffectedMeeting()
        defer { try? FileManager.default.removeItem(at: meeting.base) }
        let micBytes = try Data(contentsOf: meeting.mic)
        let systemBytes = try Data(contentsOf: meeting.system)
        // A rebuild a kill left behind, and a folder date History may sort by.
        let stale = meeting.dir.appendingPathComponent(".meeting-rebuild-left-by-a-kill.m4a")
        try Data("partial".utf8).write(to: stale)
        let folderDate = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: folderDate], ofItemAtPath: meeting.dir.path)

        let rebuild = try #require(try MeetingAudioRepair.rebuildCombinedFile(in: meeting.dir))

        #expect(abs(rebuild.before - 15) < 0.01)
        #expect(abs(rebuild.after - 5) < 0.005)
        let file = try AVAudioFile(forReading: meeting.combined)
        #expect(file.processingFormat.sampleRate == 48_000)
        #expect(file.processingFormat.channelCount == 2)
        #expect(abs(try seconds(meeting.combined) - 5) < 0.005)
        // The lanes are only read.
        #expect(try Data(contentsOf: meeting.mic) == micBytes)
        #expect(try Data(contentsOf: meeting.system) == systemBytes)
        // Nothing left beside it, and the folder keeps its date.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: meeting.dir.path)
            .filter { $0.hasPrefix(".meeting-rebuild-") }
        #expect(leftovers.isEmpty)
        let modified = try #require(
            try meeting.dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )
        #expect(abs(modified.timeIntervalSince(folderDate)) < 1)

        // A second run finds a correct file and leaves it alone.
        let rebuiltBytes = try Data(contentsOf: meeting.combined)
        #expect(try MeetingAudioRepair.rebuildCombinedFile(in: meeting.dir) == nil)
        #expect(try Data(contentsOf: meeting.combined) == rebuiltBytes)
    }

    /// The stored length goes with the audio; afterwards the folder is done.
    @Test func storedDurationIsCorrectedAndTheMeetingDropsOut() throws {
        let meeting = try makeAffectedMeeting()
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
        #expect(MeetingAudioRepair.meetingsNeedingRepair(in: meeting.base).isEmpty)
    }

    /// Both lanes at 48 kHz: the old combine was right, nothing is touched.
    @Test func aCorrectMeetingIsLeftAlone() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-repair-tests-\(UUID().uuidString)", isDirectory: true)
        let dir = base.appendingPathComponent("meeting-2026-11-18-163652", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let mic = dir.appendingPathComponent("mic.m4a")
        let system = dir.appendingPathComponent("system.m4a")
        let combined = dir.appendingPathComponent("meeting.m4a")
        try writeTone(mic, sampleRate: 48_000, channels: 1, frames: 96_000)
        try writeTone(system, sampleRate: 48_000, channels: 2, frames: 120_000)
        try Recorder.combineChannels(micURL: mic, systemURL: system, outputURL: combined)
        let bytes = try Data(contentsOf: combined)

        #expect(MeetingAudioRepair.inspect(dir)?.needsRepair == false)
        #expect(MeetingAudioRepair.meetingsNeedingRepair(in: base).isEmpty)
        #expect(try MeetingAudioRepair.rebuildCombinedFile(in: dir) == nil)
        #expect(try Data(contentsOf: combined) == bytes)
    }
}
