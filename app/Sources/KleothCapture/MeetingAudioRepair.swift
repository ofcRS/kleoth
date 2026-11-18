import Foundation
import AVFoundation
import KleothCore

/// Repairs the meetings the combine up to 0.5.7 got wrong: with a microphone
/// that was not at 48 kHz (a Bluetooth headset at 16 kHz, a MacBook's array at
/// 44.1 kHz) it wrote both lanes at the microphone's rate, so `meeting.m4a`
/// lasted up to three times the meeting and the other side played slowed down
/// (``MeetingAudioLanes``). The lane files (`mic.m4a`, `system.m4a`) were
/// always right, so the combined file is rebuilt from them.
///
/// The app runs it once per launch (`RecordingController.repairCombinedAudioAtLaunch`);
/// `recombine` runs it from a shell. File work only, safe off the main actor.
public enum MeetingAudioRepair {
    /// What a meeting folder's audio files report.
    public struct Inspection: Sendable {
        public var lanes: MeetingAudioLanes
        /// The combined file's length, or nil when there is none to read.
        public var combinedSeconds: Double?
        /// The combined file is the old combine's and must be rebuilt.
        public var combinedNeedsRebuild: Bool
        /// `meta.json` / `variant.json` files whose stored length is the old combine's.
        public var storedDurationsToCorrect: [URL]

        public var needsRepair: Bool { combinedNeedsRebuild || !storedDurationsToCorrect.isEmpty }
    }

    /// One rebuilt `meeting.m4a`: its length before and after.
    public struct Rebuild: Sendable, Equatable {
        public var before: Double
        public var after: Double
    }

    public enum RepairError: Error, LocalizedError {
        /// The rebuilt file did not come out as long as the lanes: it was
        /// thrown away and the old one kept.
        case rebuiltLengthWrong(seconds: Double, expected: Double)

        public var errorDescription: String? {
            switch self {
            case let .rebuiltLengthWrong(seconds, expected):
                return String(format: "the rebuilt meeting audio lasts %.1f s, not %.1f s; kept the old file", seconds, expected)
            }
        }
    }

    static let combinedFileName = "meeting.m4a"
    /// The rebuild is written beside the old file under this prefix (hidden,
    /// `.m4a` so `AVAudioFile` picks the format), then renamed over it.
    static let temporaryPrefix = ".meeting-rebuild-"

    /// The lanes as their files report them: a missing, unopenable or empty
    /// file is no lane, as in the combine.
    public static func lanes(in dir: URL) -> MeetingAudioLanes {
        MeetingAudioLanes(
            mic: lane(dir.appendingPathComponent(Recorder.micFileName)),
            system: lane(dir.appendingPathComponent(Recorder.systemFileName))
        )
    }

    /// What `dir` holds, or nil when it has no lane to rebuild from. Read-only.
    public static func inspect(_ dir: URL) -> Inspection? {
        let lanes = lanes(in: dir)
        guard lanes.expectedSeconds != nil else { return nil }
        let combinedSeconds = seconds(of: dir.appendingPathComponent(combinedFileName))
        let store = MeetingStore(baseDir: dir.deletingLastPathComponent())
        return Inspection(
            lanes: lanes,
            combinedSeconds: combinedSeconds,
            combinedNeedsRebuild: combinedSeconds.map { lanes.combinedNeedsRebuild(combinedSeconds: $0) } ?? false,
            storedDurationsToCorrect: store.storedAudioDurationsNeedingCorrection(in: dir, lanes: lanes)
        )
    }

    /// Every `meeting-*` folder directly under `baseDir` that needs either
    /// repair, oldest first. Read-only: three file opens and a JSON read or
    /// two per meeting.
    public static func meetingsNeedingRepair(in baseDir: URL) -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return folders
            .filter { $0.lastPathComponent.hasPrefix("meeting-") }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .filter { inspect($0)?.needsRepair == true }
    }

    /// Rebuilds `meeting.m4a` from the lanes when — and only when — it is the
    /// old combine's file; nil when there was nothing to rebuild.
    ///
    /// The new file is written beside the old one, checked to last as long as
    /// the lanes, then renamed over it (atomic on one volume): a crash or a
    /// failure at any step leaves the old file in place and the next run
    /// starts over (a stale temporary file is removed first). `mic.m4a` and
    /// `system.m4a` are only read. The folder keeps its modification date,
    /// which History falls back on to order a meeting with no start time.
    /// Idempotent: a rebuilt file no longer matches the old combine's length.
    public static func rebuildCombinedFile(in dir: URL) throws -> Rebuild? {
        guard let inspection = inspect(dir), inspection.combinedNeedsRebuild,
              let before = inspection.combinedSeconds,
              let expected = inspection.lanes.expectedSeconds else { return nil }
        let fm = FileManager.default
        // Before anything in the folder changes: the sweep below moves it too.
        let folderModified = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        removeTemporaryFiles(in: dir)

        let combined = dir.appendingPathComponent(combinedFileName)
        let temporary = dir.appendingPathComponent("\(temporaryPrefix)\(UUID().uuidString).m4a")
        do {
            try Recorder.combineChannels(
                micURL: dir.appendingPathComponent(Recorder.micFileName),
                systemURL: dir.appendingPathComponent(Recorder.systemFileName),
                outputURL: temporary
            )
            let after = seconds(of: temporary) ?? 0
            guard !MeetingAudioLanes.differ(after, expected) else {
                throw RepairError.rebuiltLengthWrong(seconds: after, expected: expected)
            }
            guard rename(temporary.path, combined.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if let folderModified {
                try? fm.setAttributes([.modificationDate: folderModified], ofItemAtPath: dir.path)
            }
            return Rebuild(before: before, after: after)
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    /// Removes rebuilds a crash or a kill left behind in `dir`.
    static func removeTemporaryFiles(in dir: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        where name.hasPrefix(temporaryPrefix) && name.hasSuffix(".m4a") {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    private static func lane(_ url: URL) -> MeetingAudioLanes.Lane? {
        guard FileManager.default.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url),
              file.length > 0, file.processingFormat.sampleRate > 0 else { return nil }
        return MeetingAudioLanes.Lane(frames: file.length, sampleRate: file.processingFormat.sampleRate)
    }

    private static func seconds(of url: URL) -> Double? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return AudioProbe.durationSeconds(of: url)
    }
}
