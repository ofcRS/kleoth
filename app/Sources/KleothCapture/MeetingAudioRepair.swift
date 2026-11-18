import Foundation
import AVFoundation
import KleothCore

/// Repairs the meetings the combine up to 0.5.7 got wrong: with a microphone
/// that did not run at the system lane's rate (a Bluetooth headset at 16 kHz,
/// a MacBook's array at 44.1 kHz) it wrote both lanes at the microphone's
/// rate, so the other side played at the wrong speed and `meeting.m4a` could
/// last up to three times the meeting (``MeetingAudioLanes``). The lane files
/// (`mic.m4a`, `system.m4a`) were always right, so the combined file is
/// rebuilt from them. A `meeting.m4a` that exists but cannot be read (a
/// combine cut short) is rebuilt too.
///
/// The app runs it at launch (`RecordingController.repairCombinedAudioAtLaunch`);
/// `recombine` runs it from a shell. File work only, safe off the main actor.
public enum MeetingAudioRepair {
    /// What a meeting folder's audio files report.
    public struct Inspection: Sendable {
        public var lanes: MeetingAudioLanes
        /// `meeting.m4a` is there at all.
        public var combinedExists: Bool
        /// Its length and rate, when it opens and holds audio.
        public var combinedSeconds: Double?
        public var combinedSampleRate: Double?
        /// It carries the mark every combine since the fix leaves (``isMarkedResampled(_:)``).
        public var combinedMarked: Bool
        /// The combined file must be rebuilt: the old combine's, or unreadable.
        public var combinedNeedsRebuild: Bool
        /// `meta.json` / `variant.json` files whose stored length is the old combine's.
        public var storedDurationsToCorrect: [URL]

        public var needsRepair: Bool { combinedNeedsRebuild || !storedDurationsToCorrect.isEmpty }
    }

    /// The launch pass's first look at a folder.
    public enum Triage: Sendable, Equatable {
        /// Nothing to do.
        case fine
        /// Rebuild the audio, correct the stored length, or both.
        case needsRepair
        /// A file it needs is not downloaded (an evicted cloud file): left
        /// alone so the scan never downloads it; looked at again later.
        case unavailable
    }

    /// One rebuilt `meeting.m4a`: its length before (nil when it could not be
    /// read) and after.
    public struct Rebuild: Sendable, Equatable {
        public var before: Double?
        public var after: Double
    }

    public enum RepairError: Error, LocalizedError, Equatable {
        /// The rebuilt file did not come out as long as the lanes: it was
        /// thrown away and the old one kept.
        case rebuiltLengthWrong(seconds: Double, expected: Double)
        /// A lane file is not downloaded; the rebuild would have downloaded it.
        case notDownloaded

        public var errorDescription: String? {
            switch self {
            case let .rebuiltLengthWrong(seconds, expected):
                return String(format: "the rebuilt meeting audio lasts %.1f s, not %.1f s; kept the old file", seconds, expected)
            case .notDownloaded:
                return "the meeting's audio is not downloaded from its cloud folder"
            }
        }
    }

    static let combinedFileName = "meeting.m4a"
    /// The rebuild is written beside the old file under this prefix (hidden,
    /// `.m4a` so `AVAudioFile` picks the format), then renamed over it.
    static let temporaryPrefix = ".meeting-rebuild-"

    // MARK: - The mark

    /// An extended attribute on every combined file written since the fix:
    /// both lanes were resampled to one rate. It tells the new files from the
    /// old where the rate cannot (a microphone above the system lane's rate),
    /// and lets the scan skip them without opening a lane. Losing it in a copy
    /// costs one more rebuild, never a wrong file.
    static let resampledAttribute = "dev.kleoth.combine"
    static let resampledValue = "resampled"

    /// Whether `url` carries the mark. Reads the attribute only, never the file.
    public static func isMarkedResampled(_ url: URL) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = getxattr(url.path, resampledAttribute, &buffer, buffer.count, 0, 0)
        guard count > 0 else { return false }
        return String(decoding: buffer.prefix(count), as: UTF8.self) == resampledValue
    }

    /// Marks a combined file `Recorder.combine` just wrote. Best effort: a
    /// volume without extended attributes only loses the shortcut.
    static func markResampled(_ url: URL) {
        let bytes = Array(resampledValue.utf8)
        _ = setxattr(url.path, resampledAttribute, bytes, bytes.count, 0, 0)
    }

    // MARK: - Cloud folders

    /// Whether `url` is a placeholder whose contents live in the cloud (an
    /// evicted iCloud Drive or File Provider file): opening it would download
    /// it. `lstat` and the resource values read metadata only.
    public static func isNotDownloaded(_ url: URL) -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) != 0 { return true }
        let values = try? URL(fileURLWithPath: url.path)
            .resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        return values?.isUbiquitousItem == true && values?.ubiquitousItemDownloadingStatus == .notDownloaded
    }

    // MARK: - Inspection

    /// The lanes as their files report them: a missing, unopenable or empty
    /// file is no lane, as in the combine.
    public static func lanes(in dir: URL) -> MeetingAudioLanes {
        MeetingAudioLanes(
            mic: lane(dir.appendingPathComponent(Recorder.micFileName)),
            system: lane(dir.appendingPathComponent(Recorder.systemFileName))
        )
    }

    /// What `dir` holds, or nil when it has no lane to rebuild from. Opens all
    /// three audio files (headers only) and reads the stored costs.
    public static func inspect(_ dir: URL) -> Inspection? {
        let lanes = lanes(in: dir)
        guard lanes.expectedSeconds != nil else { return nil }
        let combinedURL = dir.appendingPathComponent(combinedFileName)
        let exists = FileManager.default.fileExists(atPath: combinedURL.path)
        let file = exists ? (try? AVAudioFile(forReading: combinedURL)) : nil
        let readable = file.map { $0.length > 0 && $0.processingFormat.sampleRate > 0 } ?? false
        let rate = readable ? file?.processingFormat.sampleRate : nil
        let seconds = readable ? file.map { Double($0.length) / $0.processingFormat.sampleRate } : nil
        let marked = exists && isMarkedResampled(combinedURL)
        let needsRebuild: Bool
        if !exists {
            needsRebuild = false   // a missing one is rebuilt when it is needed (`rebuildCombinedAudioIfMissing`)
        } else if let rate {
            needsRebuild = lanes.combinedNeedsRebuild(combinedSampleRate: rate, resampled: marked)
        } else {
            needsRebuild = true    // there but unreadable or empty: a combine cut short
        }
        let store = MeetingStore(baseDir: dir.deletingLastPathComponent())
        return Inspection(
            lanes: lanes,
            combinedExists: exists,
            combinedSeconds: seconds,
            combinedSampleRate: rate,
            combinedMarked: marked,
            combinedNeedsRebuild: needsRebuild,
            storedDurationsToCorrect: store.storedAudioDurationsNeedingCorrection(in: dir, lanes: lanes)
        )
    }

    /// The scan's look at one folder, as cheap as it can be: a marked
    /// `meeting.m4a` is fine without opening anything (unless `deep`, for a
    /// folder whose stored length may still be pending), a missing one is not
    /// this repair's, and a file that is not downloaded is never opened.
    public static func triage(_ dir: URL, deep: Bool = false) -> Triage {
        let combined = dir.appendingPathComponent(combinedFileName)
        guard FileManager.default.fileExists(atPath: combined.path) else { return .fine }
        if !deep, isMarkedResampled(combined) { return .fine }
        let files = [combined, dir.appendingPathComponent(Recorder.micFileName),
                     dir.appendingPathComponent(Recorder.systemFileName)]
        if files.contains(where: isNotDownloaded) { return .unavailable }
        return inspect(dir)?.needsRepair == true ? .needsRepair : .fine
    }

    /// The `meeting-*` folders directly under `baseDir`, oldest first.
    public static func meetingFolders(in baseDir: URL) -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return folders
            .filter { $0.lastPathComponent.hasPrefix("meeting-") }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Every `meeting-*` folder directly under `baseDir` that needs repair,
    /// oldest first, and those it could not look at (not downloaded).
    public static func scan(_ baseDir: URL, deep: Bool = false) -> (needsRepair: [URL], unavailable: [URL]) {
        var needsRepair: [URL] = []
        var unavailable: [URL] = []
        for dir in meetingFolders(in: baseDir) {
            switch triage(dir, deep: deep) {
            case .needsRepair: needsRepair.append(dir)
            case .unavailable: unavailable.append(dir)
            case .fine: break
            }
        }
        return (needsRepair, unavailable)
    }

    // MARK: - Rebuild

    /// Rebuilds `meeting.m4a` from the lanes when — and only when — it is the
    /// old combine's file or unreadable; nil when there was nothing to rebuild.
    /// Idempotent: a rebuilt file carries the mark. Never downloads a lane.
    public static func rebuildCombinedFile(in dir: URL) throws -> Rebuild? {
        try rebuildCombinedFile(in: dir, combine: Recorder.combineChannels)
    }

    /// The same, with the combine injectable (tests make it fail).
    static func rebuildCombinedFile(
        in dir: URL, combine: (URL, URL, URL) throws -> URL
    ) throws -> Rebuild? {
        let files = [dir.appendingPathComponent(combinedFileName), dir.appendingPathComponent(Recorder.micFileName),
                     dir.appendingPathComponent(Recorder.systemFileName)]
        if files.contains(where: isNotDownloaded) { throw RepairError.notDownloaded }
        guard let inspection = inspect(dir), inspection.combinedNeedsRebuild else { return nil }
        let after = try writeCombinedFile(in: dir, combine: combine)
        return Rebuild(before: inspection.combinedSeconds, after: after)
    }

    /// Combines the lanes into `meeting.m4a` without ever leaving a broken one:
    /// written beside it, checked to last as long as the lanes, flushed to the
    /// disk (`F_FULLFSYNC`), then renamed over it (atomic on one volume). Any
    /// failure — or a cancelled task (the combine checks between chunks) —
    /// removes the new file and keeps whatever was there. `mic.m4a` and
    /// `system.m4a` are only read; the folder keeps its modification date
    /// (History orders a meeting with no start time by it), on failure too.
    /// Returns the new file's length.
    @discardableResult
    public static func writeCombinedFile(in dir: URL) throws -> Double {
        try writeCombinedFile(in: dir, combine: Recorder.combineChannels)
    }

    static func writeCombinedFile(in dir: URL, combine: (URL, URL, URL) throws -> URL) throws -> Double {
        let fm = FileManager.default
        let mic = dir.appendingPathComponent(Recorder.micFileName)
        let system = dir.appendingPathComponent(Recorder.systemFileName)
        if [mic, system].contains(where: isNotDownloaded) { throw RepairError.notDownloaded }
        guard let expected = lanes(in: dir).expectedSeconds else {
            throw RecorderError.missingSourceFile(mic)
        }

        // Before anything in the folder changes: the sweep, the new file and
        // the rename all move it.
        let folderModified = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        defer {
            if let folderModified {
                try? fm.setAttributes([.modificationDate: folderModified], ofItemAtPath: dir.path)
            }
        }
        removeTemporaryFiles(in: dir)

        let combined = dir.appendingPathComponent(combinedFileName)
        let temporary = dir.appendingPathComponent("\(temporaryPrefix)\(UUID().uuidString).m4a")
        do {
            _ = try combine(mic, system, temporary)
            let after = seconds(of: temporary) ?? 0
            guard !MeetingAudioLanes.differ(after, expected) else {
                throw RepairError.rebuiltLengthWrong(seconds: after, expected: expected)
            }
            try flushToDisk(temporary)
            guard rename(temporary.path, combined.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return after
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    /// `F_FULLFSYNC`: the file's bytes reach the disk itself (plain `fsync`
    /// leaves them in the drive's cache), so a power cut after the rename
    /// cannot leave a `meeting.m4a` that was never written out.
    private static func flushToDisk(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_FULLFSYNC) == 0 else {
            // Not every file system supports it (some network volumes): fall back.
            guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return
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
