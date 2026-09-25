import Foundation

/// The Usage row's numbers: covers created in a window that cost something,
/// and what they cost in USD as OpenRouter reported it.
public struct CoverTally: Sendable, Equatable {
    public var covers: Int
    public var cost: Double

    public init(covers: Int, cost: Double) {
        self.covers = covers
        self.cost = cost
    }

    public static let empty = CoverTally(covers: 0, cost: 0)
}

public enum CoverStoreError: Error, LocalizedError, Equatable {
    /// The meeting folder no longer exists (deleted or moved mid-draw). The
    /// store never recreates it: a cover must not resurrect a trashed meeting.
    case meetingFolderMissing(URL)

    public var errorDescription: String? {
        switch self {
        case .meetingFolderMissing:
            return "The meeting folder is gone."
        }
    }
}

/// A meeting's cover on disk (design doc 2026-09-24 §3.5, §4.1, §4.5): the
/// picture (`cover.jpg`, or a `cover.png` the user dropped in) and the
/// `cover.json` sidecar holding a `CoverRecord`. `meta.json` is never touched.
///
/// Pure file I/O, no actor: callers pick the thread. Moving files to the Trash
/// goes through an injected `trash` closure (`FileManager.trashItem` in the
/// app) so tests can observe it without touching the real Trash.
public struct CoverStore: Sendable {
    /// Where an installed cover lands. Every engine's output is normalized to JPEG.
    public static let imageFileName = "cover.jpg"
    public static let recordFileName = "cover.json"
    /// Pictures History shows, in order of preference.
    public static let displayableImageNames = ["cover.jpg", "cover.png"]
    /// `install`'s temp file: `.cover-<uuid>.tmp` in the meeting folder.
    public static let temporaryFilePrefix = ".cover-"
    public static let temporaryFileSuffix = ".tmp"
    /// A temp file older than this is debris from a kill mid-install; a
    /// younger one may belong to a draw in flight (`kleoth illustrate` while
    /// the app launches, or a job of the app's own).
    public static let temporaryFileMaxAge: TimeInterval = 3_600

    public init() {}

    // MARK: - Reading

    /// The picture to show, preferring `cover.jpg`; nil when there is none.
    public func imageURL(in meetingDir: URL) -> URL? {
        let fm = FileManager.default
        return Self.displayableImageNames
            .map { meetingDir.appendingPathComponent($0) }
            .first { fm.fileExists(atPath: $0.path) }
    }

    /// The decoded `cover.json`; nil when there is none or it doesn't decode.
    public func record(in meetingDir: URL) -> CoverRecord? {
        guard let data = try? Data(contentsOf: recordURL(in: meetingDir)) else { return nil }
        return try? MeetingStore.makeDecoder().decode(CoverRecord.self, from: data)
    }

    /// Whether `cover.json` exists at all, decodable or not.
    public func hasRecord(in meetingDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: recordURL(in: meetingDir).path)
    }

    /// Whether `summary.json` exists: the scene is written from the summary,
    /// never from the transcript, so no summary means no cover.
    public func hasSummary(in meetingDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: meetingDir.appendingPathComponent("summary.json").path)
    }

    /// `summary.json` present, no picture, no record. Any `cover.json` counts,
    /// even an undecodable one: a file is a decision (or a hand edit), and
    /// nothing automatic overrides it. A picture the user dropped in is kept.
    public func isEligibleForAutomaticCover(in meetingDir: URL) -> Bool {
        hasSummary(in: meetingDir) && imageURL(in: meetingDir) == nil && !hasRecord(in: meetingDir)
    }

    // MARK: - Writing

    /// Installs a new picture and its record. The bytes go to a temp file
    /// inside the folder (so the final rename stays on one volume), then every
    /// previous picture goes through `trash`, then the rename, then the record.
    /// Any failure removes the temp file and rethrows.
    ///
    /// Previous pictures are trashed least-preferred first, so `cover.jpg` —
    /// the one History shows — is the last to go before the rename: a `trash`
    /// that fails at any step leaves the shown picture in place, and a New
    /// Cover that fails there changes nothing the user sees (§5).
    ///
    /// Never creates `meetingDir`: a folder deleted mid-draw fails with
    /// `CoverStoreError.meetingFolderMissing` instead of being resurrected.
    public func install(jpeg: Data, record: CoverRecord, in meetingDir: URL, trash: (URL) throws -> Void) throws {
        try requireFolder(meetingDir)
        sweepTemporaryFiles(in: meetingDir)
        let fm = FileManager.default
        let temp = meetingDir.appendingPathComponent(
            Self.temporaryFilePrefix + UUID().uuidString + Self.temporaryFileSuffix)
        do {
            try jpeg.write(to: temp)
            // Every previous picture goes to the Trash — a stray cover.png too,
            // or it would linger behind the new jpg and reappear if that went.
            for name in Self.displayableImageNames.reversed() {
                let previous = meetingDir.appendingPathComponent(name)
                if fm.fileExists(atPath: previous.path) { try trash(previous) }
            }
            let destination = meetingDir.appendingPathComponent(Self.imageFileName)
            // A trash that "succeeded" but left the file would make the move fail.
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: temp, to: destination)
            try writeRecord(record, in: meetingDir)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// Writes `cover.json` atomically (a `skipped` scene, or the tail of
    /// `install` / `remove`). Never creates `meetingDir`.
    public func writeRecord(_ record: CoverRecord, in meetingDir: URL) throws {
        try requireFolder(meetingDir)
        let data = try MeetingStore.makeEncoder().encode(record)
        try data.write(to: recordURL(in: meetingDir), options: .atomic)
    }

    /// Remove Cover: every picture goes through `trash` (least-preferred
    /// first, as in `install`, so a failing `trash` leaves the shown picture),
    /// then `cover.json` records `removed` so no cover is drawn automatically
    /// again. Written even when there was no picture. Draw Cover still works
    /// afterwards. The record is written last, so a write that fails after a
    /// successful trash leaves no `removed` mark, and a meeting with no earlier
    /// `cover.json` is eligible for an automatic cover again.
    public func remove(in meetingDir: URL, now: Date, trash: (URL) throws -> Void) throws {
        try requireFolder(meetingDir)
        for name in Self.displayableImageNames.reversed() {
            let picture = meetingDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: picture.path) { try trash(picture) }
        }
        try writeRecord(CoverRecord(state: .removed, createdAt: CoverRecord.timestamp(now)), in: meetingDir)
    }

    /// Removes the `.cover-*.tmp` files in `meetingDir` older than `maxAge`
    /// (design §10, known gap: a kill between the temp write and the rename
    /// leaves one). Younger ones stay — see `temporaryFileMaxAge`. Returns what
    /// it removed; a missing or unreadable folder yields nothing and never throws.
    @discardableResult
    public func sweepTemporaryFiles(
        in meetingDir: URL, now: Date = Date(), maxAge: TimeInterval = temporaryFileMaxAge
    ) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: meetingDir.path) else { return [] }
        var removed: [URL] = []
        for name in names where name.hasPrefix(Self.temporaryFilePrefix) && name.hasSuffix(Self.temporaryFileSuffix) {
            let url = meetingDir.appendingPathComponent(name)
            guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > maxAge,
                  (try? fm.removeItem(at: url)) != nil
            else { continue }
            removed.append(url)
        }
        return removed.sorted { $0.path < $1.path }
    }

    // MARK: - Usage

    /// Adds up the covers drawn since `since` that cost something. A removed
    /// or replaced cover's record no longer carries its cost, so it drops out;
    /// free engines (Codex, a local server) report no cost and are not counted.
    public func tally(meetingDirs: [URL], since: Date) -> CoverTally {
        var tally = CoverTally.empty
        for dir in meetingDirs {
            guard let record = record(in: dir), record.state == .drawn,
                  let created = record.createdDate, created >= since,
                  let cost = record.cost, cost > 0 else { continue }
            tally.covers += 1
            tally.cost += cost
        }
        return tally
    }

    // MARK: - Private

    private func recordURL(in meetingDir: URL) -> URL {
        meetingDir.appendingPathComponent(Self.recordFileName)
    }

    private func requireFolder(_ dir: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CoverStoreError.meetingFolderMissing(dir)
        }
    }
}
