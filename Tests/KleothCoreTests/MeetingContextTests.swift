import Testing
import Foundation
@testable import KleothCore

@Suite struct MeetingContextTests {
    @Test func roundTripsExactSnakeCaseKeys() throws {
        var context = MeetingContext()
        context.startedFrom = "offer"; context.appName = "Google Chrome"; context.appBundleId = "com.google.Chrome"
        context.service = "Google Meet"; context.windowTitle = "Weekly sync - Google Meet"
        context.calendarTitle = "Weekly sync"; context.calendarStart = "2026-09-24T10:00:00Z"; context.calendarEnd = "2026-09-24T10:30:00Z"
        context.micSeconds = 1712; context.calendarOtherAttendees = 2
        let metadata = MeetingMetadata(title: "Weekly sync", date: "2026-09-24", context: context)
        let data = try MeetingStore.makeEncoder().encode(metadata)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stored = try #require(json["context"] as? [String: Any])
        #expect(Set(stored.keys) == ["app_bundle_id", "app_name", "calendar_end", "calendar_other_attendees", "calendar_start", "calendar_title", "mic_seconds", "service", "started_from", "window_title"])
        let back = try MeetingStore.makeDecoder().decode(MeetingMetadata.self, from: data)
        #expect(back.context == context)
    }

    @Test func absentContextDecodesNil() throws {
        let data = Data(#"{"title":"Old","date":"2026-06-01","participants":[],"consent_acknowledged":true}"#.utf8)
        let metadata = try MeetingStore.makeDecoder().decode(MeetingMetadata.self, from: data)
        #expect(metadata.context == nil)
        // A context with every key missing decodes to all-nil, not a failure.
        let empty = Data(#"{"title":"Old","date":"2026-06-01","participants":[],"consent_acknowledged":true,"context":{}}"#.utf8)
        #expect(try MeetingStore.makeDecoder().decode(MeetingMetadata.self, from: empty).context == MeetingContext())
    }

    @Test func placeholderTitleWithAndWithoutService() {
        let start = Date(timeIntervalSince1970: 1_758_708_300)   // 2025-09-24 10:05 UTC (the title carries no year)
        let utc = TimeZone(identifier: "UTC")!
        #expect(MeetingNaming.placeholderTitle(service: "Zoom", startedAt: start, timeZone: utc) == "Recording · Zoom · Sep 24, 10:05")
        #expect(MeetingNaming.placeholderTitle(service: nil, startedAt: start, timeZone: utc) == "Recording · Sep 24, 10:05")
        #expect(MeetingNaming.placeholderTitle(service: "  ", startedAt: start, timeZone: utc) == "Recording · Sep 24, 10:05")
        #expect(MeetingMetadata.isPlaceholderTitle(MeetingNaming.placeholderTitle(service: "Zoom", startedAt: start, timeZone: utc)))
        #expect(MeetingMetadata.isPlaceholderTitle(MeetingNaming.placeholderTitle(service: nil, startedAt: start, timeZone: utc)))
    }

    @Test func defaultSpeakerNamesNameTheSoleOtherParticipant() {
        // No calendar event: the mic is the user, the system channel "Them".
        #expect(MeetingNaming.defaultSpeakerNames(userName: "Anna", participants: []) == ["speaker_0": "Anna", "speaker_1": "Them"])
        #expect(MeetingNaming.defaultSpeakerNames(userName: "", participants: []) == ["speaker_0": "You", "speaker_1": "Them"])
        #expect(MeetingNaming.defaultSpeakerNames(userName: "  ", participants: []) == ["speaker_0": "You", "speaker_1": "Them"])
        // A one-to-one call: the system channel is that one person (Q6).
        #expect(MeetingNaming.defaultSpeakerNames(userName: "", participants: ["Boris"]) == ["speaker_0": "You", "speaker_1": "Boris"])
        #expect(MeetingNaming.defaultSpeakerNames(userName: "", participants: [" "]) == ["speaker_0": "You", "speaker_1": "Them"])
        // Two or more others: the system channel is everyone else.
        #expect(MeetingNaming.defaultSpeakerNames(userName: "Anna", participants: ["Boris", "Chris"]) == ["speaker_0": "Anna", "speaker_1": "Them"])
        // The organizer listed again as a nameless attendee is one person
        // (`CalendarParticipants.names` dedupes by address), so the call is one-to-one.
        typealias A = CalendarParticipants.Attendee
        let me = A(name: "Me", email: "mailto:me@acme.com", isUser: true, isRoomOrResource: false)
        let boris = A(name: nil, email: "mailto:boris.ivanov@acme.com", isUser: false, isRoomOrResource: false)
        let organizer = A(name: "Boris Ivanov", email: "mailto:Boris.Ivanov@acme.com", isUser: false, isRoomOrResource: false)
        let participants = CalendarParticipants.names(attendees: [me, boris], organizer: organizer)
        #expect(MeetingNaming.defaultSpeakerNames(userName: "", participants: participants)["speaker_1"] == "Boris Ivanov")
    }

    /// Branch review (phase 2) M4 / Q6: one readable name is not one person.
    /// A three-person event with one nameless attendee (`otherAttendees` 2)
    /// keeps "Them"; a `meta.json` from before the count (nil) keeps the
    /// names rule.
    @Test func defaultSpeakerNamesNeedExactlyOneOtherAttendee() {
        #expect(MeetingNaming.defaultSpeakerNames(userName: "", participants: ["Boris"], otherAttendees: 2)["speaker_1"] == "Them")
        #expect(MeetingNaming.defaultSpeakerNames(userName: "", participants: ["Boris"], otherAttendees: 1)["speaker_1"] == "Boris")
        #expect(MeetingNaming.defaultSpeakerNames(userName: "", participants: ["Boris"], otherAttendees: nil)["speaker_1"] == "Boris")
        #expect(MeetingNaming.defaultSpeakerNames(userName: "", participants: [], otherAttendees: 1)["speaker_1"] == "Them")
        typealias A = CalendarParticipants.Attendee
        let me = A(name: "Me", email: "mailto:me@acme.com", isUser: true, isRoomOrResource: false)
        let boris = A(name: "Boris", email: "mailto:b@acme.com", isUser: false, isRoomOrResource: false)
        let nameless = A(name: nil, email: "urn:uuid:5A1C", isUser: false, isRoomOrResource: false)
        let names = CalendarParticipants.names(attendees: [me, boris, nameless], organizer: nil)
        let count = CalendarParticipants.otherAttendeeCount(attendees: [me, boris, nameless], organizer: nil)
        #expect(MeetingNaming.defaultSpeakerNames(userName: "Anna", participants: names, otherAttendees: count)
            == ["speaker_0": "Anna", "speaker_1": "Them"])
    }

    @Test func startOriginRawValues() {
        #expect(MeetingStartOrigin.pill.rawValue == "pill")
        #expect(MeetingStartOrigin.offer.rawValue == "offer")
        #expect(MeetingStartOrigin.menu.rawValue == "menu")
        #expect(MeetingStartOrigin.shortcut.rawValue == "shortcut")
    }
}
