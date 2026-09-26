import Foundation

/// Single source of truth for call detection (meetings-in-the-pill design
/// §4.1); the `ScreenRecordingDefaults` rule — nothing else redefines these.
public enum MeetingDetectionDefaults {
    public static let callAppDwell: TimeInterval = 5
    public static let chatAppDwell: TimeInterval = 30
    public static let browserCallDwell: TimeInterval = 8
    /// A browser with no call seen, and apps outside the catalog (§9 Q4).
    public static let otherDwell: TimeInterval = 60
    /// A shorter gap (a device switch, a Bluetooth reconnect) keeps the session.
    public static let releaseGrace: TimeInterval = 8
    public static let offerLifetime: TimeInterval = 30
    /// The deadline moves to this after the pointer leaves the pill.
    public static let hoverLinger: TimeInterval = 5
    /// After ✕ / ignored: no offer for the same source (anarlog's cooldown).
    public static let dismissCooldown: TimeInterval = 600
    /// A session first seen longer ago than this is never offered.
    public static let maxOfferAge: TimeInterval = 600
    public static let stopGrace: TimeInterval = 20
    public static let stopOfferLifetime: TimeInterval = 60
    public static let minContextSeconds: TimeInterval = 20
    /// A refused show (the pill was busy) is retried after this.
    public static let busyRetry: TimeInterval = 1
    /// Full re-reads after a Core Audio notification.
    public static let triggerRereads: [TimeInterval] = [0.3, 1.5]
    public static let pollWhileHeld: TimeInterval = 3
    public static let pollIdle: TimeInterval = 10
    public static let titleCacheSeconds: TimeInterval = 30
}

/// What kind of thing holds the microphone (design §3.2.2).
public enum MeetingSourceClass: String, Sendable, CaseIterable, Codable {
    case callApp, chatApp, browserCall, browser, otherApp

    /// Continuous mic time before an offer.
    public var dwell: TimeInterval {
        switch self {
        case .callApp: return MeetingDetectionDefaults.callAppDwell
        case .chatApp: return MeetingDetectionDefaults.chatAppDwell
        case .browserCall: return MeetingDetectionDefaults.browserCallDwell
        case .browser, .otherApp: return MeetingDetectionDefaults.otherDwell
        }
    }

    /// Offer order when several sources are due — lower first
    /// (call app > browser call > chat app > browser > other app, §3.2.3).
    public var rank: Int {
        switch self {
        case .callApp: return 0
        case .browserCall: return 1
        case .chatApp: return 2
        case .browser: return 3
        case .otherApp: return 4
        }
    }
}
