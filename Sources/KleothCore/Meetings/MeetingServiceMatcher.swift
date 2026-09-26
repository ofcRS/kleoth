import Foundation

/// Which meeting service a window title names (design §3.2.2). Patterns from
/// the open-source detectors the design cites; re-checked by calibration.
public enum MeetingServiceMatcher {
    public struct Match: Equatable, Sendable {
        public let id: String
        public let name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    public static let maxStoredTitleLength = 120

    /// A matched title as it is stored (capped; never a title that matched nothing).
    public static func storedTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxStoredTitleLength else { return trimmed }
        return String(trimmed.prefix(maxStoredTitleLength))
    }

    public static func match(windowTitle: String) -> Match? {
        let title = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let lower = title.lowercased()

        // Google Meet: "Meet - abc-defg-hij" / "<event> - Google Meet". Never the bare landing page.
        if lower.range(of: #"^meet\s[-–—]\s[a-z]{3}-[a-z]{4}-[a-z]{3}\b"#, options: .regularExpression) != nil
            || lower.hasSuffix("- google meet") || lower.hasSuffix("– google meet") || lower.hasSuffix("— google meet") {
            return Match(id: "google-meet", name: "Google Meet")
        }
        // Teams: "<name> | Microsoft Teams", except the idle surfaces.
        if lower.hasSuffix("| microsoft teams") {
            let head = lower.dropLast("| microsoft teams".count).trimmingCharacters(in: .whitespaces)
            let idle: Set<String> = ["", "chat", "calendar", "activity", "teams", "calls", "files"]
            if !idle.contains(head) { return Match(id: "teams", name: "Teams") }
            return nil
        }
        // "<name>'s Zoom Meeting", or the app's bare "Zoom Meeting" / "Zoom
        // Webinar" — the whole title, so "how to schedule a zoom meeting -
        // Google Search" or a help page's "How to Schedule a Zoom Meeting" is no call.
        if lower.range(of: #"^(?:.+['’]s\s+)?zoom (meeting|webinar)$"#, options: .regularExpression) != nil {
            return Match(id: "zoom", name: "Zoom")
        }
        if lower.hasSuffix("- webex") || lower.hasSuffix("– webex") || lower.range(of: #"^meeting\s\|.*webex"#, options: .regularExpression) != nil {
            return Match(id: "webex", name: "Webex")
        }
        // The rest by name, only as the title's LAST words ("standup | Jitsi
        // Meet", "Планёрка — Яндекс Телемост"). The shapes are unverified (§6
        // step 9); any other place is unsafe: a search page puts the query
        // first ("jitsi meet - Google Search"), and its title would be stored.
        for (id, name, suffixes) in suffixServices where endsWithService(lower, suffixes) {
            return Match(id: id, name: name)
        }
        return nil
    }

    /// Services matched only by `endsWithService`: id, name, lowercase title endings.
    private static let suffixServices: [(id: String, name: String, suffixes: [String])] = [
        ("whereby", "Whereby", ["whereby"]),
        ("jitsi", "Jitsi Meet", ["jitsi meet"]),
        ("telemost", "Telemost", ["yandex telemost", "яндекс телемост", "telemost", "телемост"]),
        ("kontur-talk", "Kontur.Talk", ["kontur.talk", "контур.толк"]),
        ("vk-calls", "VK Calls", ["vk calls", "vk звонки"]),
        ("jazz", "Jazz", ["sberjazz", "jazz by sber"]),
    ]

    /// "<head> <separator> <service>": something, a space, a dash or a bar,
    /// then one of `suffixes` as the title's last words. Never the bare name
    /// (a landing page, like Meet's) and never the name followed by anything else.
    private static func endsWithService(_ lower: String, _ suffixes: [String]) -> Bool {
        suffixes.contains { suffix in
            let pattern = #"^.*\S\s+[-–—|]\s*"# + NSRegularExpression.escapedPattern(for: suffix) + "$"
            return lower.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// Lowercase tokens a calendar event's URL / location / notes would carry
    /// for a service — given its id ("google-meet") or its name ("Google Meet").
    public static func linkTokens(forService service: String) -> [String] {
        switch service.lowercased() {
        case "google-meet", "google meet": return ["meet.google.com", "google meet"]
        case "zoom": return ["zoom.us", "zoom"]
        case "teams": return ["teams.microsoft.com", "teams.live.com", "microsoft teams"]
        case "webex": return ["webex"]
        case "facetime": return ["facetime"]
        case "whereby": return ["whereby.com", "whereby"]
        case "jitsi", "jitsi meet": return ["meet.jit.si", "jitsi"]
        case "telemost": return ["telemost.yandex", "telemost", "телемост"]
        case "kontur-talk", "kontur.talk": return ["talk.kontur", "kontur.talk", "контур.толк"]
        case "vk-calls", "vk calls": return ["vk.com/call", "vk calls", "vk звонки"]
        case "jazz": return ["jazz.sber", "sberjazz"]
        default: return [service.lowercased()]
        }
    }
}
