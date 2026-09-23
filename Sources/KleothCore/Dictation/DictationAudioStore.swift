import Foundation

/// `<output>/dictations/audio/` — where a dictation's clip waits while its row
/// is pending (dictation-retry design §3.2).
///
/// A clip lands here only when a run could not produce a transcript (Scribe
/// failed twice, the audio could not be prepared, the user stopped it), and
/// leaves when a retry transcribes it or the row is deleted. A dictation that
/// pasted keeps no audio at all. Plain synchronous file operations on one
/// folder — renames and deletes — so a value type suffices; the row that
/// names each file lives in the day files (`DictationLogStore`).
public struct DictationAudioStore: Sendable {
    /// `<dictations>/audio`.
    public let directory: URL

    public init(dictationsDirectory: URL) {
        self.directory = dictationsDirectory.appendingPathComponent(
            DictationDefaults.keptAudioDirectoryName,
            isDirectory: true
        )
    }

    /// Where the kept clip `name` lives, or nil when `name` is not a plain
    /// file name. The name comes from a day file the user owns and may edit;
    /// it must never reach outside this folder (`../2026-09-22.json`).
    public func url(forFileNamed name: String) -> URL? {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains(":")
        else { return nil }
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    /// Moves `source` into the folder as `<id>.<ext>` and returns that name.
    /// Creates the folder on first use. A move, not a copy: the temp clip is
    /// gone afterwards, so the run's cleanup cannot delete what was kept.
    @discardableResult
    public func keep(_ source: URL, id: String) throws -> String {
        let fileExtension = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
        let name = "\(id).\(fileExtension)"
        guard let destination = url(forFileNamed: name) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: source, to: destination)
        return name
    }

    /// Deletes a kept clip for good — the retry that transcribed it succeeded.
    /// A missing file is fine.
    public func remove(fileNamed name: String) {
        guard let url = url(forFileNamed: name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Moves a kept clip to the Trash (the row was deleted, or nothing points
    /// at it any more). Returns false when there was nothing to trash or the
    /// Trash refused; the caller decides whether to delete instead.
    @discardableResult
    public func trash(fileNamed name: String) -> Bool {
        guard let url = url(forFileNamed: name),
              FileManager.default.fileExists(atPath: url.path)
        else { return false }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            return false
        }
    }

    /// Kept clips older than `age` whose names are not in `referenced` — the
    /// launch sweep's candidates (it passes nothing, then asks
    /// `DictationLogStore.audioFileNamesMentioned(among:)` which of these a
    /// record still names). Young files are skipped so a keep that has moved
    /// its clip but not yet written its row is never raced.
    public func orphans(referenced: Set<String>, olderThan age: TimeInterval, now: Date = Date()) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = now.addingTimeInterval(-age)
        return entries
            .filter { url in
                guard !referenced.contains(url.lastPathComponent) else { return false }
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true, let modified = values?.contentModificationDate else { return false }
                return modified < cutoff
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
