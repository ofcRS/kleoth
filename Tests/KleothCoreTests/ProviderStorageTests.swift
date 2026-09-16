import Testing
import Foundation
@testable import KleothCore

@Suite struct ProviderStorageTests {
    static func snakeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func snakeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    @Test func metadataRoundTripsSummaryProvider() throws {
        var meta = MeetingMetadata(title: "T", date: "2026-09-16")
        meta.summaryProvider = AIProvider.claudeCode.rawValue
        let data = try Self.snakeEncoder().encode(meta)
        #expect(String(decoding: data, as: UTF8.self).contains(#""summary_provider":"claude-code""#))
        let back = try Self.snakeDecoder().decode(MeetingMetadata.self, from: data)
        #expect(back.summaryProvider == "claude-code")
    }

    @Test func legacyMetadataWithoutProviderDecodes() throws {
        let legacy = #"{"title":"T","date":"2026-01-01","participants":[],"consent_acknowledged":false}"#
        let meta = try Self.snakeDecoder().decode(MeetingMetadata.self, from: Data(legacy.utf8))
        #expect(meta.summaryProvider == nil)
    }

    @Test func logEntryRoundTripsPolishProvider() throws {
        let entry = DictationLogEntry(timestamp: "2026-09-16T10:00:00Z", rawText: "r", polishedText: "p",
                                      polishModel: "haiku", polishProvider: "claude-code")
        let data = try Self.snakeEncoder().encode(entry)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""polish_provider":"claude-code""#))
        let back = try Self.snakeDecoder().decode(DictationLogEntry.self, from: data)
        #expect(back.polishProvider == "claude-code")
        // Explicit encoding writes the key even when nil.
        let bare = DictationLogEntry(timestamp: "2026-09-16T10:00:00Z", rawText: "r", polishedText: "p")
        let bareText = String(decoding: try Self.snakeEncoder().encode(bare), as: UTF8.self)
        #expect(bareText.contains(#""polish_provider":null"#))
    }

    @Test func legacyLogRowWithoutProviderDecodes() throws {
        let legacy = #"{"id":"1","timestamp":"2026-09-03T15:14:09Z","raw_text":"r","polished_text":"p"}"#
        let entry = try Self.snakeDecoder().decode(DictationLogEntry.self, from: Data(legacy.utf8))
        #expect(entry.polishProvider == nil)
    }
}
