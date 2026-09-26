import Foundation

/// An app, or a call in a browser, holding the microphone (design §4.1).
public struct MeetingSource: Sendable, Hashable {
    /// "app:us.zoom.xos" | "site:google-meet" | "webcall:com.google.Chrome" | "browser:com.google.Chrome"
    public var key: String
    /// What the pill says: "Zoom", "Google Meet", "Chrome".
    public var name: String
    public var sourceClass: MeetingSourceClass
    public var appBundleId: String
    public var appName: String
    /// Only a title that matched a meeting pattern, capped.
    public var windowTitle: String?

    public init(key: String, name: String, sourceClass: MeetingSourceClass, appBundleId: String, appName: String, windowTitle: String? = nil) {
        self.key = key; self.name = name; self.sourceClass = sourceClass
        self.appBundleId = appBundleId; self.appName = appName; self.windowTitle = windowTitle
    }

    /// Verdict + the app's window titles + whether it holds a web-call
    /// assertion → a source, or nil for `.never`.
    public static func make(bundleId: String, appName: String, windowTitles: [String], hasWebCall: Bool) -> MeetingSource? {
        let matched = windowTitles.lazy.compactMap { title -> (MeetingServiceMatcher.Match, String)? in
            MeetingServiceMatcher.match(windowTitle: title).map { ($0, MeetingServiceMatcher.storedTitle(title)) }
        }.first
        switch MeetingAppCatalog.verdict(bundleId: bundleId, appName: appName) {
        case .never:
            return nil
        case .app(let sourceClass, let name, _):
            return MeetingSource(key: "app:\(bundleId)", name: name, sourceClass: sourceClass,
                                 appBundleId: bundleId, appName: name, windowTitle: matched?.1)
        case .browser(let name):
            if let (match, title) = matched {
                return MeetingSource(key: "site:\(match.id)", name: match.name, sourceClass: .browserCall,
                                     appBundleId: bundleId, appName: name, windowTitle: title)
            }
            if hasWebCall {
                return MeetingSource(key: "webcall:\(bundleId)", name: name, sourceClass: .browserCall,
                                     appBundleId: bundleId, appName: name, windowTitle: nil)
            }
            return MeetingSource(key: "browser:\(bundleId)", name: name, sourceClass: .browser,
                                 appBundleId: bundleId, appName: name, windowTitle: nil)
        }
    }

    /// The thing the offer names: "Zoom call", "Slack huddle", "Call in Chrome",
    /// "Chrome is using the mic", "Telemost is using the mic" (§3.2.3).
    public var offerSubject: String {
        switch sourceClass {
        case .callApp: return "\(name) call"
        case .chatApp: return name == "Slack" ? "Slack huddle" : "\(name) call"
        case .browserCall: return key.hasPrefix("site:") ? "\(name) call" : "Call in \(appName)"
        case .browser: return "\(appName) is using the mic"
        case .otherApp: return "\(name) is using the mic"
        }
    }

    /// The quiet button: "Never for Zoom" / "Never for calls in Chrome" (§3.2.4).
    public var neverLabel: String {
        key.hasPrefix("webcall:") ? "Never for calls in \(appName)" : "Never for \(name)"
    }
}

/// The prompts' copy, in one place so a test can pin it.
public enum MeetingOfferText {
    public static let maxCalendarTitle = 40

    public static func offer(for source: MeetingSource, calendarTitle: String?) -> String {
        if let title = calendarTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            let cut = title.count > maxCalendarTitle ? String(title.prefix(maxCalendarTitle)) + "…" : title
            return "“\(cut)” on \(source.name) — record it?"
        }
        return "\(source.offerSubject) — record it?"
    }

    public static func stop(for source: MeetingSource) -> String {
        "\(source.name) released the mic — stop recording?"
    }
}
