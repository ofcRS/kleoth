import EventKit
import Foundation
import KleothCore

/// EventKit → the Core matcher (meetings-in-the-pill design §3.2.6). Every
/// entry checks the authorization status first and returns nil without full
/// access: it never requests access (only Settings does, on the user's
/// click — `RecordingController.requestCalendarAccess`) and never creates an
/// `EKEventStore` without it. Nothing here logs: event titles and attendees
/// stay out of the log.
enum CalendarLookup {
    /// The event a meeting belongs to: its title, the other people in it
    /// (`CalendarParticipants.names`), and its span.
    struct Info: Equatable {
        var title: String
        var participants: [String]
        var start: Date
        var end: Date
    }

    /// Full access to events already given. A class-level status read: no
    /// store, no prompt.
    static var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// The events overlapping ±`CalendarEventMatcher.window` of `date`, mapped
    /// for the matcher; nil without full access.
    static func candidates(around date: Date) -> [CalendarCandidate]? {
        guard isAuthorized else { return nil }
        return events(around: date).map(candidate)
    }

    /// The event `CalendarEventMatcher.best` picks for a recording that started
    /// at `date` (`serviceHint`: the detected service, e.g. "Zoom" — a link to
    /// it in the event wins), with a non-blank title; nil without full access
    /// or without such an event.
    static func meetingInfo(at date: Date, serviceHint: String?) -> Info? {
        guard isAuthorized else { return nil }
        let pairs = events(around: date).map { (event: $0, candidate: candidate($0)) }
        guard let best = CalendarEventMatcher.best(pairs.map(\.candidate), at: date, serviceId: serviceHint),
              let event = pairs.first(where: { $0.candidate == best })?.event,
              let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        let participants = CalendarParticipants.names(
            attendees: (event.attendees ?? []).map(attendee),
            organizer: event.organizer.map(attendee)
        )
        return Info(title: title, participants: participants, start: event.startDate, end: event.endDate)
    }

    // MARK: - EventKit

    private static func events(around date: Date) -> [EKEvent] {
        let store = EKEventStore()
        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-CalendarEventMatcher.window),
            end: date.addingTimeInterval(CalendarEventMatcher.window),
            calendars: nil
        )
        return store.events(matching: predicate)
    }

    private static func candidate(_ event: EKEvent) -> CalendarCandidate {
        let attendees = event.attendees ?? []
        let others = attendees.filter { !$0.isCurrentUser && !isRoomOrResource($0) }
        let declined = attendees.contains { $0.isCurrentUser && $0.participantStatus == .declined }
        // Where a call link can sit: the URL field, the location, the notes.
        let link = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: " ")
        return CalendarCandidate(
            title: event.title ?? "", start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
            isCancelled: event.status == .canceled, declinedByUser: declined,
            otherAttendeeCount: others.count, linkText: link
        )
    }

    /// `EKParticipant.url` is the address (`mailto:…`; a `urn:uuid:` for some
    /// accounts) — `CalendarParticipants` strips the scheme and reads no name
    /// from a non-address.
    private static func attendee(_ participant: EKParticipant) -> CalendarParticipants.Attendee {
        CalendarParticipants.Attendee(
            name: participant.name, email: participant.url.absoluteString,
            isUser: participant.isCurrentUser, isRoomOrResource: isRoomOrResource(participant)
        )
    }

    private static func isRoomOrResource(_ participant: EKParticipant) -> Bool {
        participant.participantType == .room || participant.participantType == .resource
    }
}
