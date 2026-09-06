import Testing
import Foundation
@testable import KleothCore

/// The dictation history store (design §3.8/§3.9, §5.7, §6.3): day files, the
/// snake_case round-trip, lenient decoding, and the actor's serialization
/// guarantee.
@Suite struct DictationLogStoreTests {
    /// A throwaway output directory; the store appends `dictations/` under it.
    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kleoth-dictation-log-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeEntry(
        id: String = UUID().uuidString,
        timestamp: String = "2026-09-03T15:14:09Z",
        rawText: String = "raw",
        polishedText: String = "Polished."
    ) -> DictationLogEntry {
        DictationLogEntry(
            id: id,
            timestamp: timestamp,
            appBundleId: "com.tinyspeck.slackmacgap",
            appName: "Slack",
            language: "rus",
            rawText: rawText,
            polishedText: polishedText,
            usedRawFallback: false,
            fallbackReason: nil,
            transcriptionModel: DictationDefaults.transcriptionModel,
            polishModel: DictationDefaults.polishModel,
            durationSeconds: 8.4,
            insertMethod: .paste,
            transcriptionCost: 0.000616,
            polishCost: 0.00011,
            polishSeconds: 1.2
        )
    }

    private func topLevelKeys(_ url: URL) throws -> Set<String> {
        let data = try Data(contentsOf: url)
        let array = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let first = try #require(array.first)
        return Set(first.keys)
    }

    // MARK: - Append / format

    @Test func appendCreatesDayFileWithExactSnakeCaseKeys() async throws {
        let dir = try makeTempDir()
        let store = DictationLogStore(outputDir: dir)
        let date = Date(timeIntervalSince1970: 1_772_812_449)
        let url = try await store.append(makeEntry(), on: date)

        #expect(url.lastPathComponent == DictationLogStore.dayFileName(for: date))
        #expect(url.deletingLastPathComponent().lastPathComponent == "dictations")
        #expect(try topLevelKeys(url) == [
            "id", "timestamp", "app_bundle_id", "app_name", "language",
            "raw_text", "polished_text", "used_raw_fallback", "fallback_reason",
            "transcription_model", "polish_model", "duration_seconds",
            "insert_method", "transcription_cost", "polish_cost", "polish_seconds",
        ])
    }

    /// The acronym-trap guard: every field must survive
    /// convertToSnakeCase → convertFromSnakeCase unchanged.
    @Test func entryRoundTripsThroughEncoderAndDecoder() async throws {
        let dir = try makeTempDir()
        let store = DictationLogStore(outputDir: dir)
        let entry = makeEntry(id: "ROUND-TRIP")
        try await store.append(entry, on: Date())

        let loaded = try #require(store.loadAll().first)
        #expect(loaded == entry)
        #expect(loaded.appBundleId == "com.tinyspeck.slackmacgap")
        #expect(loaded.transcriptionCost == 0.000616)
        #expect(loaded.polishCost == 0.00011)
        #expect(loaded.polishSeconds == 1.2)
        #expect(loaded.durationSeconds == 8.4)
        #expect(loaded.insertMethod == .paste)
    }

    @Test func appendPreservesPriorEntriesAndOrder() async throws {
        let dir = try makeTempDir()
        let store = DictationLogStore(outputDir: dir)
        let date = Date(timeIntervalSince1970: 1_772_812_449)
        try await store.append(makeEntry(id: "first", rawText: "one"), on: date)
        try await store.append(makeEntry(id: "second", rawText: "two"), on: date)

        let day = DictationLogStore.dayFileName(for: date)
        let entries = store.loadDay(named: day)
        #expect(entries.map(\.id) == ["first", "second"]) // oldest-first within a day
    }

    @Test func appendCreatesDirectoryLazily() async throws {
        let dir = try makeTempDir()
        let store = DictationLogStore(outputDir: dir)
        #expect(!FileManager.default.fileExists(atPath: store.baseDir.path))

        try await store.append(makeEntry(), on: Date())
        #expect(FileManager.default.fileExists(atPath: store.baseDir.path))
    }

    /// The reason the store is an actor: two dictations finishing back-to-back
    /// issue their appends from separate tasks, and a read-modify-write of one
    /// day file would clobber one of them.
    @Test func concurrentAppendsBothSurvive() async throws {
        let dir = try makeTempDir()
        let store = DictationLogStore(outputDir: dir)
        let date = Date(timeIntervalSince1970: 1_772_812_449)

        async let first: Void = { try await store.append(makeEntry(id: "a", rawText: "a"), on: date) }()
        async let second: Void = { try await store.append(makeEntry(id: "b", rawText: "b"), on: date) }()
        _ = try await (first, second)

        let day = DictationLogStore.dayFileName(for: date)
        let entries = store.loadDay(named: day)
        #expect(entries.count == 2)
        #expect(Set(entries.map(\.id)) == ["a", "b"])

        // …and the file is still a valid JSON array, not a torn write.
        let data = try Data(contentsOf: store.dayFileURL(named: day))
        #expect((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] != nil)
    }

    // MARK: - Reads

    @Test func loadDayReturnsEmptyForMissingFile() throws {
        let dir = try makeTempDir()
        let store = DictationLogStore(outputDir: dir)
        #expect(store.loadDay(named: "2026-01-01").isEmpty)
        #expect(store.loadAll().isEmpty)
        #expect(store.availableDays().isEmpty)
    }

    @Test func corruptDayFileIsMovedAsideAndNewRecordLands() async throws {
        let dir = try makeTempDir()
        let store = DictationLogStore(outputDir: dir)
        let date = Date(timeIntervalSince1970: 1_772_812_449)
        let day = DictationLogStore.dayFileName(for: date)
        try FileManager.default.createDirectory(at: store.baseDir, withIntermediateDirectories: true)
        try Data("{ not json at all".utf8).write(to: store.dayFileURL(named: day))

        try await store.append(makeEntry(id: "survivor"), on: date)

        #expect(store.loadDay(named: day).map(\.id) == ["survivor"])
        let names = try FileManager.default.contentsOfDirectory(atPath: store.baseDir.path)
        #expect(names.contains { $0.contains(".corrupt-") })
        // A quarantined file is not a day: it must not show up in the sidebar.
        #expect(store.availableDays() == [String(day.dropLast(".json".count))])
    }

    @Test func loadDayDecodesLenientlyWhenOptionalKeysAbsent() throws {
        let dir = try makeTempDir()
        let store = DictationLogStore(outputDir: dir)
        try FileManager.default.createDirectory(at: store.baseDir, withIntermediateDirectories: true)
        let json = """
        [{"id": "minimal", "timestamp": "2026-09-03T15:14:09Z",
          "raw_text": "raw", "polished_text": "clean"}]
        """
        try Data(json.utf8).write(to: store.dayFileURL(named: "2026-09-03"))

        let entry = try #require(store.loadDay(named: "2026-09-03").first)
        #expect(entry.id == "minimal")
        #expect(entry.appBundleId == nil)
        #expect(entry.usedRawFallback == false)
        #expect(entry.insertMethod == .paste)
        #expect(entry.date != nil)
    }

    /// A `Codable` enum throws on an unknown string — which would take the whole
    /// day file down. The lenient mapping keeps the row and defaults to `.paste`.
    @Test func unknownInsertMethodDecodesAsPaste() throws {
        let dir = try makeTempDir()
        let store = DictationLogStore(outputDir: dir)
        try FileManager.default.createDirectory(at: store.baseDir, withIntermediateDirectories: true)
        let json = """
        [{"id": "future", "timestamp": "2026-09-03T15:14:09Z", "raw_text": "r",
          "polished_text": "p", "insert_method": "teleport"}]
        """
        try Data(json.utf8).write(to: store.dayFileURL(named: "2026-09-03"))

        let entries = store.loadDay(named: "2026-09-03")
        #expect(entries.count == 1)
        #expect(entries.first?.insertMethod == .paste)
    }

    @Test func loadAllReturnsNewestFirstAcrossDaysAndRespectsLimit() async throws {
        let dir = try makeTempDir()
        let store = DictationLogStore(outputDir: dir)
        let older = Date(timeIntervalSince1970: 1_772_812_449)          // 2026-03-06
        let newer = older.addingTimeInterval(60 * 60 * 24 * 3)          // 3 days later
        try await store.append(makeEntry(id: "old-1"), on: older)
        try await store.append(makeEntry(id: "old-2"), on: older)
        try await store.append(makeEntry(id: "new-1"), on: newer)
        try await store.append(makeEntry(id: "new-2"), on: newer)

        #expect(store.availableDays().count == 2)
        #expect(store.loadAll().map(\.id) == ["new-2", "new-1", "old-2", "old-1"])
        #expect(store.loadAll(limit: 3).map(\.id) == ["new-2", "new-1", "old-2"])
        #expect(store.loadAll(limit: 0).isEmpty)
    }

    // MARK: - Delete

    @Test func deleteRemovesOnlyNamedIds() async throws {
        let dir = try makeTempDir()
        let store = DictationLogStore(outputDir: dir)
        let date = Date(timeIntervalSince1970: 1_772_812_449)
        let other = date.addingTimeInterval(60 * 60 * 24)
        try await store.append(makeEntry(id: "keep"), on: date)
        try await store.append(makeEntry(id: "drop"), on: date)
        try await store.append(makeEntry(id: "elsewhere"), on: other)

        let removed = try await store.delete(ids: ["drop"])
        #expect(removed == 1)
        #expect(store.loadDay(named: DictationLogStore.dayFileName(for: date)).map(\.id) == ["keep"])
        #expect(store.loadDay(named: DictationLogStore.dayFileName(for: other)).map(\.id) == ["elsewhere"])
        let noop = try await store.delete(ids: [])
        #expect(noop == 0)
    }

    @Test func deleteEmptyingADayRemovesTheFile() async throws {
        let dir = try makeTempDir()
        let store = DictationLogStore(outputDir: dir)
        let date = Date(timeIntervalSince1970: 1_772_812_449)
        try await store.append(makeEntry(id: "only"), on: date)
        let url = store.dayFileURL(named: DictationLogStore.dayFileName(for: date))
        #expect(FileManager.default.fileExists(atPath: url.path))

        let removed = try await store.delete(ids: ["only"])
        #expect(removed == 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(store.availableDays().isEmpty)
    }

    // MARK: - Naming

    @Test func dayFileNameUsesPOSIXLocaleAndInjectedTimeZone() {
        // 2026-09-03T23:30:00Z — still the 3rd in UTC, already the 4th in Tokyo.
        let date = Date(timeIntervalSince1970: 1_788_478_200)
        let utc = TimeZone(identifier: "UTC")!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        #expect(DictationLogStore.dayFileName(for: date, timeZone: utc) == "2026-09-03.json")
        #expect(DictationLogStore.dayFileName(for: date, timeZone: tokyo) == "2026-09-04.json")
    }
}
