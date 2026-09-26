import Testing
import Foundation
@testable import KleothCore

/// `cover.json`'s shape (design doc 2026-09-24 §4.1): the eleven acronym-free
/// keys under MeetingStore's snake_case strategies, and the `created_at` stamp
/// the Usage tally reads back.
@Suite struct CoverRecordTests {
    @Test func fullRecordEncodesExactlyElevenSnakeCaseKeys() throws {
        let record = CoverRecord(
            state: .drawn,
            reason: "sensitive",
            engine: CoverEngine.openRouter.rawValue,
            model: "google/gemini-3.1-flash-lite-image",
            style: CoverStyle.clay.rawValue,
            scene: "A lighthouse keeper's desk covered in charts.",
            sceneProvider: "claude-code",
            sceneModel: "claude-haiku",
            createdAt: "2026-09-24T10:00:00Z",
            cost: 0.041,
            seconds: 7.5
        )
        let data = try MeetingStore.makeEncoder().encode(record)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == [
            "state", "reason", "engine", "model", "style", "scene",
            "scene_provider", "scene_model", "created_at", "cost", "seconds",
        ])
        let back = try MeetingStore.makeDecoder().decode(CoverRecord.self, from: data)
        #expect(back == record)
    }

    /// Model ids carry a slash (`google/gemini-…`); the file is read by people
    /// and hand-edited, so it must not come out as `google\/gemini-…`.
    @Test func slashesAreNotEscaped() throws {
        let record = CoverRecord(state: .drawn, model: "google/gemini-3.1-flash-lite-image", createdAt: "2026-09-24T10:00:00Z")
        let text = String(decoding: try MeetingStore.makeEncoder().encode(record), as: UTF8.self)
        #expect(text.contains(#""model" : "google/gemini-3.1-flash-lite-image""#))
        #expect(!text.contains(#"\/"#))
    }

    @Test func minimalRecordDecodes() throws {
        let json = #"{"state":"removed","created_at":"2026-09-24T10:00:00Z"}"#
        let record = try MeetingStore.makeDecoder().decode(CoverRecord.self, from: Data(json.utf8))
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-09-24T10:00:00Z"))
        #expect(record.state == .removed)
        #expect(record.createdAt == "2026-09-24T10:00:00Z")
        #expect(record.createdDate == expected)
        #expect(record.reason == nil)
        #expect(record.engine == nil)
        #expect(record.model == nil)
        #expect(record.style == nil)
        #expect(record.scene == nil)
        #expect(record.sceneProvider == nil)
        #expect(record.sceneModel == nil)
        #expect(record.cost == nil)
        #expect(record.seconds == nil)
    }

    @Test func timestampRoundTrips() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000.4)
        let record = CoverRecord(state: .drawn, createdAt: CoverRecord.timestamp(date))
        // Whole seconds are stored: the fraction is dropped, the second survives.
        #expect(record.createdDate == Date(timeIntervalSince1970: 1_790_000_000))

        // With time, in UTC: the stamp reads back exactly.
        let noon = try #require(ISO8601DateFormatter().date(from: "2026-09-24T10:00:00Z"))
        #expect(CoverRecord.timestamp(noon) == "2026-09-24T10:00:00Z")
    }
}
