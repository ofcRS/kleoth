import Foundation

/// Where a meeting happened (design §3.2.6, §4.5) — stored in `meta.json` as
/// `context`, every key optional, snake_case through `MeetingStore`'s
/// strategies (acronym-free names, so each round-trips). Written once, at
/// stop, and carried whole by every later writer.
public struct MeetingContext: Codable, Sendable, Equatable {
    /// `MeetingStartOrigin` raw value.
    public var startedFrom: String?
    public var appName: String?
    public var appBundleId: String?
    /// "Zoom", "Google Meet", "Slack" — the detector's service name.
    public var service: String?
    /// Only a window title that matched a meeting pattern (capped).
    public var windowTitle: String?
    public var calendarTitle: String?
    /// ISO 8601.
    public var calendarStart: String?
    public var calendarEnd: String?
    /// How long the app held the mic during the recording.
    public var micSeconds: Double?

    public init(startedFrom: String? = nil, appName: String? = nil, appBundleId: String? = nil, service: String? = nil,
                windowTitle: String? = nil, calendarTitle: String? = nil, calendarStart: String? = nil,
                calendarEnd: String? = nil, micSeconds: Double? = nil) {
        self.startedFrom = startedFrom; self.appName = appName; self.appBundleId = appBundleId; self.service = service
        self.windowTitle = windowTitle; self.calendarTitle = calendarTitle; self.calendarStart = calendarStart
        self.calendarEnd = calendarEnd; self.micSeconds = micSeconds
    }
}

/// How a meeting was started (`MeetingContext.startedFrom`).
public enum MeetingStartOrigin: String, Sendable {
    case pill, offer, menu, shortcut
}
