import Foundation

/// Reads and writes the per-recording sidecar and lists a recordings folder.
/// Pure file I/O over `ScreenRecordingRecord`; no actor, callers pick the
/// thread (a directory listing over a big folder belongs off the main actor).
public enum ScreenRecordingStore {
    /// Every finished movie in `dir` (in-flight `.recording.mp4` files are
    /// skipped; `-recovered.mp4` files are listed), newest first.
    public static func listRecordings(in dir: URL, fileManager: FileManager = .default) -> [ScreenRecordingItem] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return [] }
        var items: [ScreenRecordingItem] = []
        for name in names where ScreenRecordingFileNaming.isFinishedRecordingName(name) {
            let url = dir.appendingPathComponent(name)
            let attributes = (try? fileManager.attributesOfItem(atPath: url.path)) ?? [:]
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let created = attributes[.creationDate] as? Date
            let recordedAt = ScreenRecordingFileNaming.date(fromStemOf: url) ?? created ?? Date(timeIntervalSince1970: 0)
            let record = loadRecord(for: url, fileManager: fileManager)
            items.append(ScreenRecordingItem(url: url, recordedAt: recordedAt, sizeBytes: size, record: record))
        }
        return items.sorted { $0.recordedAt > $1.recordedAt }
    }

    /// The sidecar for `movieURL`, or `nil` when there is none / it is unreadable.
    public static func loadRecord(for movieURL: URL, fileManager: FileManager = .default) -> ScreenRecordingRecord? {
        let sidecar = ScreenRecordingFileNaming.sidecarURL(for: movieURL)
        guard fileManager.fileExists(atPath: sidecar.path),
              let data = try? Data(contentsOf: sidecar) else { return nil }
        return try? decoder.decode(ScreenRecordingRecord.self, from: data)
    }

    /// Writes the sidecar atomically next to `movieURL`.
    public static func saveRecord(_ record: ScreenRecordingRecord, for movieURL: URL) throws {
        let data = try encoder.encode(record)
        try data.write(to: ScreenRecordingFileNaming.sidecarURL(for: movieURL), options: .atomic)
    }

    /// Moves the movie and its sidecar (if any) to the Trash.
    public static func trash(_ movieURL: URL, fileManager: FileManager = .default) throws {
        try fileManager.trashItem(at: movieURL, resultingItemURL: nil)
        let sidecar = ScreenRecordingFileNaming.sidecarURL(for: movieURL)
        if fileManager.fileExists(atPath: sidecar.path) {
            try? fileManager.trashItem(at: sidecar, resultingItemURL: nil)
        }
    }

    // MARK: - Coding

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
