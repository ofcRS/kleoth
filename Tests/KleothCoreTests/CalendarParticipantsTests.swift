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

    /// Task 11 review, minor 1: the organizer is the same PERSON as an attendee
    /// with the same address, whatever the names say — a one-to-one call counts
    /// one other person (Q6). The entry with a real name wins, in calendar order.
    @Test func sameAddressIsOnePersonAndARealNameWins() {
        let me = A(name: "Me", email: "mailto:me@acme.com", isUser: true, isRoomOrResource: false)
        let anna = A(name: "Anna Petrova", email: "mailto:ap@acme.com", isUser: false, isRoomOrResource: false)
        #expect(CalendarParticipants.names(attendees: [me, anna], organizer: A(name: nil, email: "mailto:ap@acme.com", isUser: false, isRoomOrResource: false)) == ["Anna Petrova"])
        #expect(CalendarParticipants.names(attendees: [me, anna], organizer: A(name: "Anna", email: "MAILTO:AP@acme.com ", isUser: false, isRoomOrResource: false)) == ["Anna Petrova"])
        let bare = A(name: nil, email: "mailto:ap@acme.com", isUser: false, isRoomOrResource: false)
        let boris = A(name: "Boris", email: "mailto:b@acme.com", isUser: false, isRoomOrResource: false)
        #expect(CalendarParticipants.names(attendees: [bare, boris], organizer: A(name: "Anna Petrova", email: "ap@acme.com", isUser: false, isRoomOrResource: false)) == ["Anna Petrova", "Boris"])
        // No address on one side: the same name is the same person.
        #expect(CalendarParticipants.names(attendees: [anna], organizer: A(name: "Anna Petrova", email: nil, isUser: false, isRoomOrResource: false)) == ["Anna Petrova"])
        // Two people who share a name are two people.
        let alex1 = A(name: "Alex", email: "alex1@acme.com", isUser: false, isRoomOrResource: false)
        let alex2 = A(name: "Alex", email: "alex2@acme.com", isUser: false, isRoomOrResource: false)
        #expect(CalendarParticipants.names(attendees: [alex1, alex2], organizer: nil) == ["Alex", "Alex"])
    }

    /// Task 11 review, minor 2: a name comes from an ADDRESS only — an
    /// Exchange/CalDAV `urn:uuid:` or principal path is no name — and a `+tag` is dropped.
    @Test func aNameNeedsAnAddressAndDropsAPlusTag() {
        #expect(CalendarParticipants.displayName(name: nil, email: "urn:uuid:5A1C3E2B-0000-4000-8000-000000000001") == nil)
        #expect(CalendarParticipants.displayName(name: nil, email: "/principals/users/anna/") == nil)
        #expect(CalendarParticipants.displayName(name: nil, email: "anna.petrova+cal@acme.com") == "Anna Petrova")
        #expect(CalendarParticipants.displayName(name: nil, email: "mailto:anna.petrova+cal@acme.com") == "Anna Petrova")
        #expect(CalendarParticipants.displayName(name: nil, email: "ap+cal@acme.com") == "ap+cal@acme.com")   // the whole address, as it is
        #expect(CalendarParticipants.displayName(name: "Anna", email: "urn:uuid:5A1C") == "Anna")
        let urn = A(name: nil, email: "urn:uuid:5A1C", isUser: false, isRoomOrResource: false)
        let boris = A(name: "Boris", email: "b@acme.com", isUser: false, isRoomOrResource: false)
        #expect(CalendarParticipants.names(attendees: [urn, boris], organizer: nil) == ["Boris"])
    }

    /// Branch review (phase 2) M4 / Q6: the one-to-one rule counts PEOPLE —
    /// anyone with an identity (a name, an address, or another URL such as a
    /// `urn:uuid:`) — not the names `names` can read. A three-person event
    /// with one nameless attendee has two other people.
    @Test func otherAttendeeCountCountsEveryIdentity() {
        let me = A(name: "Me", email: "mailto:me@acme.com", isUser: true, isRoomOrResource: false)
        let room = A(name: "Room 4", email: "mailto:room4@acme.com", isUser: false, isRoomOrResource: true)
        let boris = A(name: "Boris", email: "mailto:b@acme.com", isUser: false, isRoomOrResource: false)
        let urn = A(name: nil, email: "urn:uuid:5A1C", isUser: false, isRoomOrResource: false)
        let path = A(name: nil, email: "/principals/users/chris/", isUser: false, isRoomOrResource: false)

        // User + Boris + a nameless attendee: two others, one readable name.
        #expect(CalendarParticipants.names(attendees: [me, boris, urn], organizer: nil) == ["Boris"])
        #expect(CalendarParticipants.otherAttendeeCount(attendees: [me, boris, urn], organizer: nil) == 2)
        #expect(CalendarParticipants.otherAttendeeCount(attendees: [me, boris, path], organizer: nil) == 2)
        // The user and rooms never count; the organizer counts once.
        #expect(CalendarParticipants.otherAttendeeCount(attendees: [me, room, boris], organizer: boris) == 1)
        #expect(CalendarParticipants.otherAttendeeCount(
            attendees: [me, boris], organizer: A(name: nil, email: "MAILTO:B@acme.com", isUser: false, isRoomOrResource: false)) == 1)
        // The same URL twice is one person; no identity at all is no one.
        #expect(CalendarParticipants.otherAttendeeCount(attendees: [me, urn], organizer: urn) == 1)
        let blank = A(name: " ", email: " ", isUser: false, isRoomOrResource: false)
        #expect(CalendarParticipants.otherAttendeeCount(attendees: [me, boris, blank], organizer: nil) == 1)
        #expect(CalendarParticipants.otherAttendeeCount(attendees: [], organizer: nil) == 0)
    }
}
