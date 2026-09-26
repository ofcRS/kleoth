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
}
