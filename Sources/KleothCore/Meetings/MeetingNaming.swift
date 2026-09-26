import Foundation

public enum MeetingNaming {
    /// "Recording · Zoom · Sep 24, 14:05" / "Recording · Sep 24, 14:05" — the
    /// recovered-title form `RecordingController.recoveredTitle` already
    /// uses, which `MeetingMetadata.isPlaceholderTitle` treats as a
    /// placeholder, so a summary's title still replaces it (§3.2.6).
    public static func placeholderTitle(service: String?, startedAt: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d, HH:mm"
        let stamp = formatter.string(from: startedAt)
        if let service = service?.trimmingCharacters(in: .whitespacesAndNewlines), !service.isEmpty {
            return "Recording · \(service) · \(stamp)"
        }
        return "Recording · \(stamp)"
    }

    /// The default speaker map of a two-channel meeting (§3.2.6, Q6): the mic
    /// (`speaker_0`) is the user — their name, else "You" — and the system
    /// channel (`speaker_1`) is everyone else: "Them", or the one other
    /// participant when there is exactly one (a one-to-one calendar call;
    /// `CalendarParticipants.names` already leaves out the user and rooms and
    /// counts one person once) and the event has exactly one other person
    /// (`otherAttendees`, which also counts the attendees no name could be
    /// read for; nil = not known, a meeting from before it: the names decide).
    /// Written only when `speakers.json` is absent, so a rename still overrides it.
    public static func defaultSpeakerNames(userName: String, participants: [String], otherAttendees: Int? = nil) -> [String: String] {
        let user = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let oneToOne = participants.count == 1 && (otherAttendees ?? 1) == 1
        let sole = oneToOne ? participants[0].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return ["speaker_0": user.isEmpty ? "You" : user, "speaker_1": sole.isEmpty ? "Them" : sole]
    }
}
