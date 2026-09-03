import Foundation

/// The dictation history: `<outputDir>/dictations/<yyyy-MM-dd>.json`, one bare
/// JSON array per day, oldest-first within the day. Encoder/decoder follow the
/// `MeetingStore` conventions (snake_case, sortedKeys, prettyPrinted) so the
/// files stay hand-readable and the user owns them.
///
/// An **actor**, not a plain value type: `append` and `delete` are
/// read-modify-write of one file, and two dictations finishing back-to-back
/// would otherwise clobber each other. Writes serialize on the actor, off the
/// main actor (the controller `await`s them). Reads only touch the immutable
/// `baseDir`, so they are `nonisolated` and callable synchronously from SwiftUI
/// views. Every write lands via an atomic replace, so a concurrent read sees
/// either the old or the new file, never a torn one.
///
/// Audio is never stored here — dictation clips are deleted the moment the
/// pipeline exits.
public actor DictationLogStore {
    /// `<outputDir>/dictations`. Immutable, hence safe to read from anywhere.
    public nonisolated let baseDir: URL

    public init(outputDir: URL) {
        self.baseDir = outputDir.appendingPathComponent(
            DictationDefaults.logDirectoryName,
            isDirectory: true
        )
    }

    // MARK: - Day naming

    /// `"2026-09-03.json"`. Locale is pinned to `en_US_POSIX` so the file name
    /// is stable regardless of the user's region; calendar and time zone are
    /// injectable for tests.
    public static func dayFileName(
        for date: Date,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date) + ".json"
    }

    /// The file backing one day. Accepts either `"2026-09-03"` or
    /// `"2026-09-03.json"` — `availableDays()` returns the bare form,
    /// `dayFileName(for:)` the suffixed one.
    public nonisolated func dayFileURL(named day: String) -> URL {
        let name = day.hasSuffix(".json") ? day : day + ".json"
        return baseDir.appendingPathComponent(name)
    }

    // MARK: - Reads (nonisolated: pure file reads off `baseDir`)

    /// Every entry stored for one day, oldest-first. Fail-soft: a missing or
    /// unreadable file reads as empty (the write path is what quarantines a
    /// corrupt file — a read never mutates the user's data).
    public nonisolated func loadDay(named day: String) -> [DictationLogEntry] {
        let url = dayFileURL(named: day)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? Self.makeDecoder().decode([DictationLogEntry].self, from: data)) ?? []
    }

    /// Newest-first across every day file, stopping once `limit` entries are
    /// collected (so a years-old history never gets fully parsed to fill a list).
    public nonisolated func loadAll(limit: Int = 500) -> [DictationLogEntry] {
        guard limit > 0 else { return [] }
        var result: [DictationLogEntry] = []
        for day in availableDays() {
            // Stored oldest-first within a day; the list wants newest-first.
            for entry in loadDay(named: day).reversed() {
                result.append(entry)
                if result.count == limit { return result }
            }
        }
        return result
    }

    /// Bare day stamps (`"2026-09-03"`), newest-first. Quarantined
    /// (`<day>.corrupt-<uuid>.json`) and in-flight (`.tmp`) files are skipped —
    /// only exact `yyyy-MM-dd.json` names count.
    public nonisolated func availableDays() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: baseDir.path)) ?? []
        return names
            .filter { Self.isDayFileName($0) }
            .map { String($0.dropLast(".json".count)) }
            .sorted(by: >)
    }

    /// Exactly `yyyy-MM-dd.json` — digits and dashes only, so
    /// `2026-09-03.corrupt-<uuid>.json` and `2026-09-03.json.tmp` are excluded.
    private nonisolated static func isDayFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        let stem = name.dropLast(".json".count)
        guard stem.count == 10 else { return false }
        for (index, character) in stem.enumerated() {
            let expectsDash = (index == 4 || index == 7)
            if expectsDash {
                if character != "-" { return false }
            } else if !character.isASCII || !character.isNumber {
                return false
            }
        }
        return true
    }

    // MARK: - Writes (actor-isolated: serialized read-modify-write)

    /// Appends one entry to `date`'s day file, creating the directory and the
    /// file lazily. Returns the file written.
    ///
    /// A day file that no longer decodes is moved aside to
    /// `<day>.corrupt-<uuid>.json` and a fresh array started, so one bad byte
    /// never silently swallows the dictation the user just spoke (and never
    /// destroys whatever was there either).
    @discardableResult
    public func append(_ entry: DictationLogEntry, on date: Date = Date()) throws -> URL {
        let url = dayFileURL(named: Self.dayFileName(for: date))
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        var entries: [DictationLogEntry] = []
        if let data = try? Data(contentsOf: url) {
            if let decoded = try? Self.makeDecoder().decode([DictationLogEntry].self, from: data) {
                entries = decoded
            } else {
                try quarantine(url)
            }
        }
        entries.append(entry)
        try write(entries, to: url)
        return url
    }

    /// Removes the named entries wherever they live, rewriting only the day
    /// files that actually contain one and deleting any file it empties.
    /// Returns how many entries were removed.
    ///
    /// Irreversible — unlike a meeting folder this is a rewrite inside a JSON
    /// file, not a move to the Trash, which is why the UI confirms first.
    @discardableResult
    public func delete(ids: Set<String>) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        var removed = 0
        for day in availableDays() {
            let url = dayFileURL(named: day)
            let entries = loadDay(named: day)
            let kept = entries.filter { !ids.contains($0.id) }
            guard kept.count != entries.count else { continue }
            removed += entries.count - kept.count
            if kept.isEmpty {
                try FileManager.default.removeItem(at: url)
            } else {
                try write(kept, to: url)
            }
        }
        return removed
    }

    // MARK: - Private

    /// Writes through a sibling `.tmp` file and swaps it in, so a crash or a
    /// concurrent read never observes a half-written array.
    private func write(_ entries: [DictationLogEntry], to url: URL) throws {
        let data = try Self.makeEncoder().encode(entries)
        let temporary = url.appendingPathExtension("tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    /// Moves an undecodable day file out of the way, keeping its contents for
    /// the user (and out of `availableDays()`).
    private func quarantine(_ url: URL) throws {
        let stem = url.deletingPathExtension().lastPathComponent
        let target = baseDir.appendingPathComponent("\(stem).corrupt-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: url, to: target)
    }

    /// Same conventions as `MeetingStore` — the files sit side by side under
    /// `~/Kleoth` and should read alike.
    private nonisolated static func makeEncoder() -> JSONEncoder {
        MeetingStore.makeEncoder()
    }

    private nonisolated static func makeDecoder() -> JSONDecoder {
        MeetingStore.makeDecoder()
    }
}
