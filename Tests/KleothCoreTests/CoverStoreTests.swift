import Testing
import Foundation
@testable import KleothCore

/// A stand-in for `FileManager.trashItem` that records each URL and deletes the file, or throws `failure`.
final class RecordingTrash: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private let failure: (any Error)?

    init(failing failure: (any Error)? = nil) {
        self.failure = failure
    }

    /// Every URL handed to the trash, in order (including ones it refused).
    var trashed: [URL] { lock.withLock { urls } }

    func callAsFunction(_ url: URL) throws {
        lock.withLock { urls.append(url) }
        if let failure { throw failure }
        try FileManager.default.removeItem(at: url)
    }
}

/// The `cover.json` sidecar and the picture beside it (design doc 2026-09-24
/// §3.5, §4.1): which picture shows, which meetings get one automatically,
/// install/remove through the Trash seam, and the Usage tally.
@Suite struct CoverStoreTests {
    private struct TrashRefused: Error {}

    private let store = CoverStore()

    /// `<tmp>/kleoth-cover-store-tests-<uuid>/meeting-x/`, created.
    private func makeMeetingDir(_ name: String = "meeting-x") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-cover-store-tests-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func removeRoot(of dir: URL) {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func writeSummary(in dir: URL) throws {
        try Data(#"{"tldr":"t"}"#.utf8).write(to: dir.appendingPathComponent("summary.json"))
    }

    private func write(_ text: String, _ name: String, in dir: URL) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    private func read(_ name: String, in dir: URL) throws -> String {
        String(decoding: try Data(contentsOf: dir.appendingPathComponent(name)), as: UTF8.self)
    }

    private func exists(_ name: String, in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    private func drawnRecord(cost: Double? = 0.04, createdAt: String = "2026-09-24T10:00:00Z") -> CoverRecord {
        CoverRecord(
            state: .drawn, engine: "openrouter", model: "google/gemini-3.1-flash-lite-image",
            style: "sketch", scene: "A tidy workbench.", sceneProvider: "openrouter",
            sceneModel: "z-ai/glm-5.3-flash", createdAt: createdAt, cost: cost, seconds: 6.2
        )
    }

    // MARK: - Reading

    @Test func imageURLPrefersJPEGOverPNG() throws {
        let dir = try makeMeetingDir()
        defer { removeRoot(of: dir) }

        #expect(store.imageURL(in: dir) == nil)

        try write("png", "cover.png", in: dir)
        #expect(store.imageURL(in: dir) == dir.appendingPathComponent("cover.png"))

        try write("jpg", "cover.jpg", in: dir)
        #expect(store.imageURL(in: dir) == dir.appendingPathComponent("cover.jpg"))
    }

    @Test func eligibilityTable() throws {
        func eligible(_ setUp: (URL) throws -> Void) throws -> Bool {
            let dir = try makeMeetingDir()
            defer { removeRoot(of: dir) }
            try setUp(dir)
            return store.isEligibleForAutomaticCover(in: dir)
        }

        #expect(try eligible { _ in } == false)                                   // no summary
        #expect(try eligible { try writeSummary(in: $0) } == true)                // fresh
        #expect(try eligible {
            try writeSummary(in: $0)
            try write("png", "cover.png", in: $0)                                 // a picture the user dropped in
        } == false)
        #expect(try eligible {
            try writeSummary(in: $0)
            try store.writeRecord(CoverRecord(state: .skipped, reason: "sensitive", createdAt: "2026-09-24T10:00:00Z"), in: $0)
        } == false)
        #expect(try eligible {
            try writeSummary(in: $0)
            try store.writeRecord(CoverRecord(state: .removed, createdAt: "2026-09-24T10:00:00Z"), in: $0)
        } == false)
        #expect(try eligible {
            try writeSummary(in: $0)
            try write("garbage", "cover.json", in: $0)                            // a file is a file: nothing automatic
        } == false)
    }

    // MARK: - Install

    @Test func installReplacesThroughTheInjectedTrashAndLeavesNoTempFile() throws {
        let dir = try makeMeetingDir()
        defer { removeRoot(of: dir) }
        try write("old", "cover.jpg", in: dir)
        try write("stray", "cover.png", in: dir)
        let trash = RecordingTrash()
        let record = drawnRecord()

        try store.install(jpeg: Data("new".utf8), record: record, in: dir, trash: { try trash($0) })

        #expect(try read("cover.jpg", in: dir) == "new")
        // Least-preferred first: cover.jpg, the picture History shows, goes last.
        #expect(trash.trashed == [dir.appendingPathComponent("cover.png"), dir.appendingPathComponent("cover.jpg")])
        #expect(!exists("cover.png", in: dir))
        #expect(store.record(in: dir) == record)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!names.contains { $0.hasPrefix(".cover") || $0.contains("tmp") })
    }

    @Test func installIntoAMissingFolderThrowsAndCreatesNothing() throws {
        let dir = try makeMeetingDir()
        defer { removeRoot(of: dir) }
        let missing = dir.deletingLastPathComponent().appendingPathComponent("meeting-gone", isDirectory: true)
        let trash = RecordingTrash()

        #expect(throws: CoverStoreError.meetingFolderMissing(missing)) {
            try store.install(jpeg: Data("new".utf8), record: drawnRecord(), in: missing, trash: { try trash($0) })
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(trash.trashed.isEmpty)
    }

    @Test func installWithAFailingTrashKeepsTheOldPictureAndWritesNothing() throws {
        let dir = try makeMeetingDir()
        defer { removeRoot(of: dir) }
        try write("old", "cover.jpg", in: dir)
        let trash = RecordingTrash(failing: TrashRefused())

        #expect(throws: TrashRefused.self) {
            try store.install(jpeg: Data("new".utf8), record: drawnRecord(), in: dir, trash: { try trash($0) })
        }
        #expect(try read("cover.jpg", in: dir) == "old")
        #expect(!store.hasRecord(in: dir))
        #expect(store.record(in: dir) == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == ["cover.jpg"])
    }

    // MARK: - Temp files

    private func age(_ name: String, by seconds: TimeInterval, in dir: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-seconds)],
            ofItemAtPath: dir.appendingPathComponent(name).path
        )
    }

    /// A kill between `install`'s temp write and its rename leaves
    /// `.cover-<uuid>.tmp` behind (design §10, known gap). The sweep takes the
    /// stale ones; a young one may be a draw in flight (the CLI's while the app
    /// launches), so it stays; nothing else in the folder is touched.
    @Test func sweepRemovesOnlyStaleTempFiles() throws {
        let dir = try makeMeetingDir()
        defer { removeRoot(of: dir) }
        try write("x", ".cover-0F3A6A3E-1F2B-4C5D-8E9F-0A1B2C3D4E5F.tmp", in: dir)
        try age(".cover-0F3A6A3E-1F2B-4C5D-8E9F-0A1B2C3D4E5F.tmp", by: 2 * 3_600, in: dir)
        try write("x", ".cover-11111111-2222-3333-4444-555555555555.tmp", in: dir)   // fresh
        try write("jpg", "cover.jpg", in: dir)
        try write("notes", ".cover-notes", in: dir)                                    // not a temp file

        let removed = store.sweepTemporaryFiles(in: dir)

        #expect(removed == [dir.appendingPathComponent(".cover-0F3A6A3E-1F2B-4C5D-8E9F-0A1B2C3D4E5F.tmp")])
        #expect(!exists(".cover-0F3A6A3E-1F2B-4C5D-8E9F-0A1B2C3D4E5F.tmp", in: dir))
        #expect(exists(".cover-11111111-2222-3333-4444-555555555555.tmp", in: dir))
        #expect(exists("cover.jpg", in: dir))
        #expect(exists(".cover-notes", in: dir))

        // A missing folder sweeps nothing and throws nothing.
        let gone = dir.deletingLastPathComponent().appendingPathComponent("meeting-gone", isDirectory: true)
        #expect(store.sweepTemporaryFiles(in: gone).isEmpty)
    }

    @Test func installSweepsItsFolderFirst() throws {
        let dir = try makeMeetingDir()
        defer { removeRoot(of: dir) }
        try write("x", ".cover-0F3A6A3E-1F2B-4C5D-8E9F-0A1B2C3D4E5F.tmp", in: dir)
        try age(".cover-0F3A6A3E-1F2B-4C5D-8E9F-0A1B2C3D4E5F.tmp", by: 2 * 3_600, in: dir)
        let trash = RecordingTrash()

        try store.install(jpeg: Data("new".utf8), record: drawnRecord(), in: dir, trash: { try trash($0) })

        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["cover.jpg", "cover.json"])
    }

    // MARK: - Remove

    @Test func removeTrashesThePictureAndWritesRemoved() throws {
        let dir = try makeMeetingDir()
        defer { removeRoot(of: dir) }
        try write("old", "cover.jpg", in: dir)
        let trash = RecordingTrash()
        let now = Date(timeIntervalSince1970: 1_790_000_000)

        try store.remove(in: dir, now: now, trash: { try trash($0) })

        #expect(trash.trashed == [dir.appendingPathComponent("cover.jpg")])
        #expect(store.imageURL(in: dir) == nil)
        let record = try #require(store.record(in: dir))
        #expect(record.state == .removed)
        #expect(record.createdAt == CoverRecord.timestamp(now))

        // No picture: still recorded, so nothing is drawn automatically later.
        let bare = try makeMeetingDir()
        defer { removeRoot(of: bare) }
        let bareTrash = RecordingTrash()
        try store.remove(in: bare, now: now, trash: { try bareTrash($0) })
        #expect(bareTrash.trashed.isEmpty)
        #expect(store.record(in: bare)?.state == .removed)
    }

    // MARK: - Tally

    @Test func tallySumsCostInsideTheWindowAndSkipsRemovedAndOlder() throws {
        let root = try makeMeetingDir("meeting-0")
        defer { removeRoot(of: root) }
        let parent = root.deletingLastPathComponent()
        let now = Date()
        let day: TimeInterval = 86_400

        let rows: [(String, CoverRecord?)] = [
            ("today", drawnRecord(cost: 0.03, createdAt: CoverRecord.timestamp(now))),
            ("yesterday", drawnRecord(cost: 0.04, createdAt: CoverRecord.timestamp(now - day))),
            ("forty-days-ago", drawnRecord(cost: 0.10, createdAt: CoverRecord.timestamp(now - 40 * day))),
            ("removed-today", CoverRecord(state: .removed, createdAt: CoverRecord.timestamp(now), cost: 0.05)),
            ("codex-today", drawnRecord(cost: nil, createdAt: CoverRecord.timestamp(now))),
            ("no-cover", nil),
        ]
        var dirs: [URL] = []
        for (name, record) in rows {
            let dir = parent.appendingPathComponent("meeting-\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let record { try store.writeRecord(record, in: dir) }
            dirs.append(dir)
        }

        let tally = store.tally(meetingDirs: dirs, since: now - 30 * day)
        #expect(tally.covers == 2)
        #expect(abs(tally.cost - 0.07) < 1e-9)
        #expect(store.tally(meetingDirs: [], since: now) == .empty)
    }
}
