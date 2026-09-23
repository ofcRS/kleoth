import Testing
import Foundation
@testable import KleothCore

/// The kept-audio folder (dictation-retry design §3.2, §3.5): a dictation's
/// clip lives in `<output>/dictations/audio/` only while it waits to be
/// transcribed.
@Suite struct DictationAudioStoreTests {
    /// A throwaway `<output>/dictations` folder.
    private func makeDictationsDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kleoth-dictation-audio-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeClip(in dir: URL, named name: String = "prep-\(UUID().uuidString).m4a") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("not really aac".utf8).write(to: url)
        return url
    }

    @Test func keepMovesTheClipIntoTheAudioFolderUnderTheRowId() throws {
        let dictations = try makeDictationsDir()
        let scratch = try makeDictationsDir()
        let clip = try makeClip(in: scratch)
        let store = DictationAudioStore(dictationsDirectory: dictations)

        let name = try store.keep(clip, id: "ROW-1")

        #expect(name == "ROW-1.m4a")
        #expect(store.directory == dictations.appendingPathComponent("audio", isDirectory: true))
        #expect(!FileManager.default.fileExists(atPath: clip.path))
        let kept = try #require(store.url(forFileNamed: name))
        #expect(kept.deletingLastPathComponent().standardizedFileURL == store.directory.standardizedFileURL)
        #expect(try Data(contentsOf: kept) == Data("not really aac".utf8))
    }

    @Test func urlRefusesAnythingButAPlainFileName() throws {
        let store = DictationAudioStore(dictationsDirectory: try makeDictationsDir())
        #expect(store.url(forFileNamed: "ROW-1.m4a") != nil)
        #expect(store.url(forFileNamed: "../2026-09-22.json") == nil)
        #expect(store.url(forFileNamed: "/etc/hosts") == nil)
        #expect(store.url(forFileNamed: "..") == nil)
        #expect(store.url(forFileNamed: "") == nil)
    }

    @Test func removeDeletesAndIsIdempotent() throws {
        let dictations = try makeDictationsDir()
        let store = DictationAudioStore(dictationsDirectory: dictations)
        let name = try store.keep(try makeClip(in: try makeDictationsDir()), id: "GONE")
        let url = try #require(store.url(forFileNamed: name))

        store.remove(fileNamed: name)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        store.remove(fileNamed: name)   // already gone: no throw, no crash
    }

    @Test func orphansAreOldUnreferencedFilesOnly() throws {
        let dictations = try makeDictationsDir()
        let store = DictationAudioStore(dictationsDirectory: dictations)
        let scratch = try makeDictationsDir()
        let now = Date()
        let old = now.addingTimeInterval(-2 * 86_400)
        for id in ["referenced", "orphan", "young"] {
            let name = try store.keep(try makeClip(in: scratch), id: id)
            let date = id == "young" ? now.addingTimeInterval(-60) : old
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: try #require(store.url(forFileNamed: name)).path)
        }

        let orphans = store.orphans(referenced: ["referenced.m4a"], olderThan: 86_400, now: now)
        #expect(orphans.map(\.lastPathComponent) == ["orphan.m4a"])
    }

    @Test func noFolderMeansNoOrphans() throws {
        let store = DictationAudioStore(dictationsDirectory: try makeDictationsDir())
        #expect(store.orphans(referenced: [], olderThan: 0).isEmpty)
    }
}
