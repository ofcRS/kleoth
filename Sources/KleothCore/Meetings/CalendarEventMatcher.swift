import Foundation

/// An EventKit event, EventKit-free (`CalendarLookup` in the app maps it).
public struct CalendarCandidate: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var isCancelled: Bool
    public var declinedByUser: Bool
    /// Excludes the user, rooms and resources.
    public var otherAttendeeCount: Int
    /// URL + location + notes, for the service match.
    public var linkText: String

    public init(title: String, start: Date, end: Date, isAllDay: Bool, isCancelled: Bool, declinedByUser: Bool,
                otherAttendeeCount: Int, linkText: String) {
        self.title = title; self.start = start; self.end = end; self.isAllDay = isAllDay; self.isCancelled = isCancelled
        self.declinedByUser = declinedByUser; self.otherAttendeeCount = otherAttendeeCount; self.linkText = linkText
    }
}

/// Which calendar event a recording belongs to (design §3.2.6): among the
/// events overlapping ±5 min of the start — all-day, cancelled and declined
/// out — one whose URL/location/notes name the detected service beats one
/// with other attendees, which beats a solo block; then the closest start;
/// then the shorter event.
public enum CalendarEventMatcher {
    public static let window: TimeInterval = 300

    /// `serviceId` is the detected service as an id ("google-meet") or as the
    /// name the detector reports ("Google Meet"); nil → no service tier.
    public static func best(_ candidates: [CalendarCandidate], at start: Date, serviceId: String?) -> CalendarCandidate? {
        let tokens = serviceId.map { MeetingServiceMatcher.linkTokens(forService: $0) } ?? []
        func tier(_ c: CalendarCandidate) -> Int {
            let link = c.linkText.lowercased()
            if !tokens.isEmpty, tokens.contains(where: { link.contains($0) }) { return 0 }
            return c.otherAttendeeCount > 0 ? 1 : 2
        }
        return candidates
            .filter { !$0.isAllDay && !$0.isCancelled && !$0.declinedByUser }
            .filter { $0.start <= start.addingTimeInterval(window) && $0.end >= start.addingTimeInterval(-window) }
            .min { a, b in
                let ta = tier(a), tb = tier(b)
                if ta != tb { return ta < tb }
                let da = abs(a.start.timeIntervalSince(start)), db = abs(b.start.timeIntervalSince(start))
                if da != db { return da < db }
                return a.end.timeIntervalSince(a.start) < b.end.timeIntervalSince(b.start)
            }
    }
}

public enum CalendarParticipants {
    public struct Attendee: Sendable, Equatable {
        public var name: String?
        public var email: String?
        public var isUser: Bool
        public var isRoomOrResource: Bool
        public init(name: String?, email: String?, isUser: Bool, isRoomOrResource: Bool) {
            self.name = name; self.email = email; self.isUser = isUser; self.isRoomOrResource = isRoomOrResource
        }
    }

    /// Display names: the user and rooms dropped, the organizer added when
    /// missing, duplicates removed, calendar order kept.
    public static func names(attendees: [Attendee], organizer: Attendee?) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        let all = attendees + (organizer.map { [$0] } ?? [])
        for attendee in all where !attendee.isUser && !attendee.isRoomOrResource {
            guard let name = displayName(name: attendee.name, email: attendee.email) else { continue }
            let key = name.lowercased()
            if seen.insert(key).inserted { out.append(name) }
        }
        return out
    }

    /// A name, else the address's local part made readable when it has a
    /// separator ("anna.petrova@acme.com" → "Anna Petrova"), else the address.
    public static func displayName(name: String?, email: String?) -> String? {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        guard var address = email?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else { return nil }
        if address.lowercased().hasPrefix("mailto:") { address = String(address.dropFirst(7)) }
        guard let at = address.firstIndex(of: "@") else { return address }
        let local = address[..<at]
        let parts = local.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" }).filter { !$0.isEmpty }
        guard parts.count >= 2 else { return address }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }
}
