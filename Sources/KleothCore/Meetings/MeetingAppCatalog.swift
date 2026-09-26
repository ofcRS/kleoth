import Foundation

/// Which apps are calls, chats, browsers, or never a meeting (design §3.2.2).
/// Pure data and path rules — no AppKit, so it is testable on the Core floor.
/// Bundle ids marked "unverified" come from the design's list and are
/// corrected by calibration (§6 step 9 / the manual checklist); detection ships
/// off by default, so a wrong entry costs a missed offer, never a recording.
public enum MeetingAppCatalog {
    public enum Verdict: Equatable, Sendable {
        /// `callApp` / `chatApp` / `otherApp`; `serviceName` is what the
        /// context stores as `service` ("Zoom") — nil for an unknown app.
        case app(MeetingSourceClass, name: String, serviceName: String?)
        case browser(name: String)
        case never
    }

    private static let callApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "Cisco-Systems.Spark": "Webex",
        "com.apple.FaceTime": "FaceTime",
        "com.apple.Phone": "Phone",                 // unverified (macOS 26 Phone app)
        "com.logmein.GoToMeeting": "GoTo Meeting",  // unverified
        "app.tuple.app": "Tuple",                   // unverified
        "co.teamport.around": "Around",             // unverified
    ]

    private static let chatApps: [String: String] = [
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
        "ru.keepcoder.Telegram": "Telegram",
        "com.tdesktop.Telegram": "Telegram",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "org.whispersystems.signal-desktop": "Signal",
        "com.facebook.archon": "Messenger",         // unverified
        "com.viber.osx": "Viber",                   // unverified
    ]

    private static let browsers: [String: String] = [
        "com.google.Chrome": "Chrome",
        "com.apple.Safari": "Safari",
        "company.thebrowser.Browser": "Arc",
        "company.thebrowser.dia": "Dia",
        "com.microsoft.edgemac": "Edge",
        "com.brave.Browser": "Brave",
        "org.mozilla.firefox": "Firefox",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "com.operasoftware.Opera": "Opera",
        "com.kagi.kagimacOS": "Orion",              // unverified
    ]

    /// Browsers whose mic capture runs in `com.apple.WebKit.GPU` (the
    /// responsible-process fallback when the symbol is missing).
    public static let webKitBrowserBundleIds: [String] = ["com.apple.Safari", "com.kagi.kagimacOS"]

    /// Exact never ids (dictation tools, recorders, music apps, processors, AI voice modes).
    private static let neverExact: Set<String> = [
        "com.electron.wispr-flow", "com.superwhisper.app", "com.goodsnooze.MacWhisper",
        "com.prakashjoshipax.VoiceInk", "com.aquavoice.app", "app.willowvoice.mac",       // last three unverified
        "com.obsproject.obs-studio", "com.loom.desktop", "pl.maciejczaplinski.CleanShot",   // CleanShot unverified
        "com.ableton.live", "ai.krisp.krispMac",
        "com.openai.chat", "com.anthropic.claudefordesktop",
    ]

    /// Never prefixes: Apple's own processes (Siri, Dictation, Sound
    /// Recognition, Voice Control, `com.apple.replayd`, Voice Memos, QuickTime,
    /// GarageBand, Logic) except the catalog's own Apple entries (FaceTime,
    /// Phone, Safari), Rogue Amoeba's tools, other Kleoth builds.
    private static let neverPrefixes: [String] = ["com.apple.", "com.rogueamoeba.", "dev.kleoth."]

    /// The named lists (call, chat, browser) are consulted BEFORE the never
    /// rules, so `com.apple.FaceTime` and `com.apple.Safari` survive the
    /// `com.apple.` prefix.
    public static func verdict(bundleId: String, appName: String) -> Verdict {
        if bundleId.isEmpty { return .never }                       // outside any .app
        if let name = callApps[bundleId] { return .app(.callApp, name: name, serviceName: name) }
        if let name = chatApps[bundleId] { return .app(.chatApp, name: name, serviceName: name) }
        if let name = browsers[bundleId] { return .browser(name: name) }
        if neverExact.contains(bundleId) { return .never }
        if neverPrefixes.contains(where: { bundleId.hasPrefix($0) }) { return .never }
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        return .app(.otherApp, name: trimmed.isEmpty ? bundleId : trimmed, serviceName: nil)
    }

    /// The outermost `.app` bundle on `executablePath`, or nil (daemons, XPC
    /// services, bare binaries).
    public static func outermostAppPath(executablePath: String) -> String? {
        guard !executablePath.isEmpty else { return nil }
        let parts = executablePath.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") && $0.count > 4 }) else { return nil }
        return parts[...index].joined(separator: "/")
    }

    /// Daemons that stand for an app, in the order the host tries them
    /// (the first one running wins).
    public static func daemonStandIn(bundleId: String) -> [String] {
        switch bundleId {
        case "com.apple.avconferenced": return ["com.apple.FaceTime", "com.apple.Phone"]
        default: return []
        }
    }

    /// Power-assertion names that mean "a live call" in a Chromium browser.
    public static let webCallAssertionNames: Set<String> = ["WebRTC has active PeerConnections"]
}
