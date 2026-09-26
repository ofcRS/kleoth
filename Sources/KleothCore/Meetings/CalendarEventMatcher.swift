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
    /// name the detector reports ("Google Meet"); nil or blank → no service tier.
    public static func best(_ candidates: [CalendarCandidate], at start: Date, serviceId: String?) -> CalendarCandidate? {
        let service = serviceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = service.flatMap { $0.isEmpty ? nil : MeetingServiceMatcher.linkTokens(forService: $0) } ?? []
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
    /// missing, one entry per person, calendar order kept. The same person =
    /// the same address, or — when one side has no address — the same name;
    /// the entry with a real name wins (a one-to-one call counts one other
    /// person, Q6). Two people who share a name stay two.
    public static func names(attendees: [Attendee], organizer: Attendee?) -> [String] {
        var out: [(name: String, address: String?, named: Bool)] = []
        let all = attendees + (organizer.map { [$0] } ?? [])
        for attendee in all where !attendee.isUser && !attendee.isRoomOrResource {
            guard let name = displayName(name: attendee.name, email: attendee.email) else { continue }
            let address = normalizedAddress(attendee.email)
            let named = !(attendee.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let same = out.firstIndex { entry in
                if let address, let other = entry.address { return address == other }
                return entry.name.lowercased() == name.lowercased()
            }
            guard let index = same else {
                out.append((name, address, named))
                continue
            }
            if named, !out[index].named { out[index].name = name; out[index].named = true }
            if out[index].address == nil { out[index].address = address }
        }
        return out.map(\.name)
    }

    /// How many other people the event has, for the one-to-one rule (Q6):
    /// everyone `names` counts, plus each attendee it can't name who still
    /// has an identity — another URL (a `urn:uuid:`, a principal path),
    /// counted once per URL. The user and rooms never count. A nameless
    /// attendee may be someone `names` already has: counting them again only
    /// costs a "Them" where a name would do, never a wrong name.
    public static func otherAttendeeCount(attendees: [Attendee], organizer: Attendee?) -> Int {
        let all = attendees + (organizer.map { [$0] } ?? [])
        var unnamed = Set<String>()
        for attendee in all where !attendee.isUser && !attendee.isRoomOrResource
            && displayName(name: attendee.name, email: attendee.email) == nil {
            guard let url = attendee.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !url.isEmpty else { continue }
            unnamed.insert(url)
        }
        return names(attendees: attendees, organizer: organizer).count + unnamed.count
    }

    /// A name, else the address's local part made readable when it has a
    /// separator ("anna.petrova+cal@acme.com" → "Anna Petrova"), else the
    /// address. Nil without an address: a `urn:uuid:` or a principal path is
    /// no name.
    public static func displayName(name: String?, email: String?) -> String? {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        guard var address = email?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else { return nil }
        if address.lowercased().hasPrefix("mailto:") { address = String(address.dropFirst(7)) }
        guard let at = address.firstIndex(of: "@"), at != address.startIndex else { return nil }
        var local = address[..<at]
        if let plus = local.firstIndex(of: "+") { local = local[..<plus] }   // a +tag is no part of the name
        let parts = local.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" }).filter { !$0.isEmpty }
        guard parts.count >= 2 else { return address }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }

    /// The address that identifies a person: `mailto:` stripped, trimmed,
    /// lowercased; nil when it is not an address.
    static func normalizedAddress(_ email: String?) -> String? {
        guard var address = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        if address.hasPrefix("mailto:") { address = String(address.dropFirst(7)) }
        guard let at = address.firstIndex(of: "@"), at != address.startIndex else { return nil }
        return address
    }
}
