import Testing
import Foundation
@testable import KleothCore

/// The personal dictionary file (design §3.10, §6.4): storage normalization,
/// the editor's text round-trip, and fail-soft loading.
@Suite struct PersonalDictionaryStoreTests {
    private func makeTempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kleoth-dictionary-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("kleoth", isDirectory: true)
            .appendingPathComponent("dictionary.json")
    }

    @Test func normalizeTrimsDedupesCaseInsensitivelyAndCaps() {
        let normalized = PersonalDictionaryStore.normalize([
            "  Kleoth  ", "", "   ", "WhisperKit", "kleoth", "KLEOTH", "Scribe",
        ])
        // First spelling wins; blanks vanish.
        #expect(normalized == ["Kleoth", "WhisperKit", "Scribe"])

        let overflow = (0..<(DictationDefaults.maxStoredDictionaryTerms + 25)).map { "term-\($0)" }
        let capped = PersonalDictionaryStore.normalize(overflow)
        #expect(capped.count == DictationDefaults.maxStoredDictionaryTerms)
        #expect(capped.first == "term-0")
        #expect(capped.last == "term-\(DictationDefaults.maxStoredDictionaryTerms - 1)")
    }

    @Test func parseAndRenderRoundTripTolerateCRLF() {
        let text = "Kleoth\r\nWhisperKit\r\n\r\n  Scribe  \nkleoth\n"
        let terms = PersonalDictionaryStore.parse(text: text)
        #expect(terms == ["Kleoth", "WhisperKit", "Scribe"])
        #expect(PersonalDictionaryStore.render(terms) == "Kleoth\nWhisperKit\nScribe")
        #expect(PersonalDictionaryStore.parse(text: PersonalDictionaryStore.render(terms)) == terms)
        #expect(PersonalDictionaryStore.parse(text: "").isEmpty)
    }

    @Test func loadReturnsEmptyForMissingOrCorruptFileAndSkipsNonStrings() throws {
        let url = makeTempURL()
        let store = PersonalDictionaryStore(url: url)
        #expect(store.load().isEmpty) // nothing on disk yet

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{{ not json".utf8).write(to: url)
        #expect(store.load().isEmpty)

        // A hand-edited file with a stray number keeps its strings.
        try Data(#"["Kleoth", 42, "Scribe", null, "kleoth"]"#.utf8).write(to: url)
        #expect(store.load() == ["Kleoth", "Scribe"])
    }

    @Test func saveCreatesParentDirectoryAndWritesArray() throws {
        let url = makeTempURL()
        let store = PersonalDictionaryStore(url: url)
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))

        try store.save(["  Kleoth ", "Scribe", "kleoth", ""])

        #expect(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([String].self, from: data)
        #expect(decoded == ["Kleoth", "Scribe"]) // normalized on the way in
        #expect(store.load() == ["Kleoth", "Scribe"])
    }
}
