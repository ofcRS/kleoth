import Testing
@testable import KleothCore

@Suite struct CalendarParticipantsTests {
    typealias A = CalendarParticipants.Attendee

    @Test func userAndRoomsDroppedOrganizerAddedOnce() {
        let attendees = [A(name: "Me", email: "me@acme.com", isUser: true, isRoomOrResource: false),
                         A(name: "Room 4", email: "room4@acme.com", isUser: false, isRoomOrResource: true),
                         A(name: "Boris", email: "boris@acme.com", isUser: false, isRoomOrResource: false),
                         A(name: "Anna Petrova", email: "anna.petrova@acme.com", isUser: false, isRoomOrResource: false)]
        let organizer = A(name: "Anna Petrova", email: "anna.petrova@acme.com", isUser: false, isRoomOrResource: false)
        #expect(CalendarParticipants.names(attendees: attendees, organizer: organizer) == ["Boris", "Anna Petrova"])
        let outside = A(name: "Chris", email: "chris@x.com", isUser: false, isRoomOrResource: false)
        #expect(CalendarParticipants.names(attendees: attendees, organizer: outside) == ["Boris", "Anna Petrova", "Chris"])
        #expect(CalendarParticipants.names(attendees: [], organizer: nil).isEmpty)
    }

    @Test func nilNameBecomesAReadableLocalPartOrTheWholeAddress() {
        #expect(CalendarParticipants.displayName(name: nil, email: "anna.petrova@acme.com") == "Anna Petrova")
        #expect(CalendarParticipants.displayName(name: nil, email: "anna_petrova@acme.com") == "Anna Petrova")
        #expect(CalendarParticipants.displayName(name: nil, email: "ap@acme.com") == "ap@acme.com")
        #expect(CalendarParticipants.displayName(name: "  ", email: "ap@acme.com") == "ap@acme.com")
        #expect(CalendarParticipants.displayName(name: "Anna", email: nil) == "Anna")
        #expect(CalendarParticipants.displayName(name: nil, email: nil) == nil)
        #expect(CalendarParticipants.displayName(name: nil, email: "mailto:anna.petrova@acme.com") == "Anna Petrova")
    }

    @Test func duplicatesRemovedOrderKept() {
        let a = A(name: "Boris", email: "b@acme.com", isUser: false, isRoomOrResource: false)
        let b = A(name: nil, email: "boris@acme.com", isUser: false, isRoomOrResource: false)
        let c = A(name: "Boris", email: "b@acme.com", isUser: false, isRoomOrResource: false)
        #expect(CalendarParticipants.names(attendees: [a, b, c], organizer: nil) == ["Boris", "boris@acme.com"])
    }
}
