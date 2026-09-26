import Testing
@testable import KleothCore

@Suite struct MeetingAppCatalogTests {
    @Test func callAppsMapToTheirClassAndName() {
        #expect(MeetingAppCatalog.verdict(bundleId: "us.zoom.xos", appName: "zoom.us") == .app(.callApp, name: "Zoom", serviceName: "Zoom"))
        #expect(MeetingAppCatalog.verdict(bundleId: "com.microsoft.teams2", appName: "Microsoft Teams") == .app(.callApp, name: "Teams", serviceName: "Teams"))
        #expect(MeetingAppCatalog.verdict(bundleId: "com.microsoft.teams", appName: "Microsoft Teams classic") == .app(.callApp, name: "Teams", serviceName: "Teams"))
        #expect(MeetingAppCatalog.verdict(bundleId: "Cisco-Systems.Spark", appName: "Webex") == .app(.callApp, name: "Webex", serviceName: "Webex"))
        #expect(MeetingAppCatalog.verdict(bundleId: "com.apple.FaceTime", appName: "FaceTime") == .app(.callApp, name: "FaceTime", serviceName: "FaceTime"))
    }

    @Test func chatAppsAreChatClass() {
        #expect(MeetingAppCatalog.verdict(bundleId: "com.tinyspeck.slackmacgap", appName: "Slack") == .app(.chatApp, name: "Slack", serviceName: "Slack"))
        #expect(MeetingAppCatalog.verdict(bundleId: "com.hnc.Discord", appName: "Discord") == .app(.chatApp, name: "Discord", serviceName: "Discord"))
        #expect(MeetingAppCatalog.verdict(bundleId: "ru.keepcoder.Telegram", appName: "Telegram") == .app(.chatApp, name: "Telegram", serviceName: "Telegram"))
        #expect(MeetingAppCatalog.verdict(bundleId: "com.tdesktop.Telegram", appName: "Telegram") == .app(.chatApp, name: "Telegram", serviceName: "Telegram"))
        #expect(MeetingAppCatalog.verdict(bundleId: "net.whatsapp.WhatsApp", appName: "WhatsApp") == .app(.chatApp, name: "WhatsApp", serviceName: "WhatsApp"))
        #expect(MeetingAppCatalog.verdict(bundleId: "org.whispersystems.signal-desktop", appName: "Signal") == .app(.chatApp, name: "Signal", serviceName: "Signal"))
    }

    @Test func browsersAreBrowsers() {
        for (id, name) in [("com.google.Chrome", "Chrome"), ("com.apple.Safari", "Safari"), ("company.thebrowser.Browser", "Arc"),
                           ("company.thebrowser.dia", "Dia"), ("com.microsoft.edgemac", "Edge"), ("com.brave.Browser", "Brave"),
                           ("org.mozilla.firefox", "Firefox"), ("com.vivaldi.Vivaldi", "Vivaldi"), ("com.operasoftware.Opera", "Opera")] {
            #expect(MeetingAppCatalog.verdict(bundleId: id, appName: "x") == .browser(name: name), "\(id)")
        }
    }

    @Test func unknownAppsAreOtherWithTheirOwnName() {
        #expect(MeetingAppCatalog.verdict(bundleId: "com.example.telemost", appName: "Telemost") == .app(.otherApp, name: "Telemost", serviceName: nil))
    }

    @Test func neverList() {
        #expect(MeetingAppCatalog.verdict(bundleId: "com.apple.replayd", appName: "replayd") == .never)
        #expect(MeetingAppCatalog.verdict(bundleId: "com.apple.Siri", appName: "Siri") == .never)
        #expect(MeetingAppCatalog.verdict(bundleId: "com.apple.VoiceMemos", appName: "Voice Memos") == .never)
        #expect(MeetingAppCatalog.verdict(bundleId: "com.electron.wispr-flow", appName: "Wispr Flow") == .never)
        #expect(MeetingAppCatalog.verdict(bundleId: "com.goodsnooze.MacWhisper", appName: "MacWhisper") == .never)
        #expect(MeetingAppCatalog.verdict(bundleId: "com.rogueamoeba.audiohijack", appName: "Audio Hijack") == .never)
        #expect(MeetingAppCatalog.verdict(bundleId: "com.obsproject.obs-studio", appName: "OBS") == .never)
        #expect(MeetingAppCatalog.verdict(bundleId: "com.ableton.live", appName: "Live") == .never)
        #expect(MeetingAppCatalog.verdict(bundleId: "ai.krisp.krispMac", appName: "Krisp") == .never)
        #expect(MeetingAppCatalog.verdict(bundleId: "com.openai.chat", appName: "ChatGPT") == .never)
        #expect(MeetingAppCatalog.verdict(bundleId: "com.anthropic.claudefordesktop", appName: "Claude") == .never)
        #expect(MeetingAppCatalog.verdict(bundleId: "dev.kleoth.app", appName: "Kleoth") == .never)
        #expect(MeetingAppCatalog.verdict(bundleId: "dev.kleoth.demo", appName: "KleothDemo") == .never)
        #expect(MeetingAppCatalog.verdict(bundleId: "", appName: "micopen") == .never)   // outside any .app
    }

    @Test func daemonStandIn() {
        #expect(MeetingAppCatalog.daemonStandIn(bundleId: "com.apple.avconferenced") == ["com.apple.FaceTime", "com.apple.Phone"])
        #expect(MeetingAppCatalog.daemonStandIn(bundleId: "com.apple.Siri").isEmpty)
    }

    @Test func outermostAppPath() {
        #expect(MeetingAppCatalog.outermostAppPath(executablePath:
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/140.0/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper")
            == "/Applications/Google Chrome.app")
        #expect(MeetingAppCatalog.outermostAppPath(executablePath: "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper") == "/Applications/Slack.app")
        #expect(MeetingAppCatalog.outermostAppPath(executablePath: "/Applications/Firefox.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container") == "/Applications/Firefox.app")
        #expect(MeetingAppCatalog.outermostAppPath(executablePath: "/Users/a/Applications/Arc.app/Contents/MacOS/Arc") == "/Users/a/Applications/Arc.app")
        #expect(MeetingAppCatalog.outermostAppPath(executablePath: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU") == nil)
        #expect(MeetingAppCatalog.outermostAppPath(executablePath: "/usr/libexec/avconferenced") == nil)
        #expect(MeetingAppCatalog.outermostAppPath(executablePath: "") == nil)
    }

    /// Review M-5: a site added to the Dock from Safari (macOS 14+) is its own
    /// app under `com.apple.Safari.WebApp.<id>` — a browser named after itself,
    /// not an Apple process.
    @Test func safariWebAppsAreBrowsersNamedAfterThemselves() throws {
        #expect(MeetingAppCatalog.verdict(bundleId: "com.apple.Safari.WebApp.5A1C3E2B", appName: "Google Meet") == .browser(name: "Google Meet"))
        #expect(MeetingAppCatalog.verdict(bundleId: "com.apple.Safari.WebApp.5A1C3E2B", appName: "  ") == .browser(name: "Safari"))
        #expect(MeetingAppCatalog.verdict(bundleId: "com.apple.Safari.WebApp.", appName: "X") == .never)             // no id
        #expect(MeetingAppCatalog.verdict(bundleId: "com.apple.Safari.SafeBrowsing", appName: "SafeBrowsing") == .never)
        let meet = try #require(MeetingSource.make(bundleId: "com.apple.Safari.WebApp.5A1C3E2B", appName: "Google Meet",
                                                   windowTitles: ["Meet - abc-defg-hij"], hasWebCall: false))
        #expect(meet.key == "site:google-meet")
        #expect(meet.sourceClass == .browserCall)
        let teams = try #require(MeetingSource.make(bundleId: "com.apple.Safari.WebApp.77", appName: "Teams", windowTitles: [], hasWebCall: false))
        #expect(teams.key == "browser:com.apple.Safari.WebApp.77")
        #expect(teams.offerSubject == "Teams is using the mic")
        #expect(teams.neverLabel == "Never for Teams")
    }

    @Test func webCallAssertionNames() {
        #expect(MeetingAppCatalog.webCallAssertionNames.contains("WebRTC has active PeerConnections"))
    }

    @Test func classDwellsAndRanks() {
        #expect(MeetingSourceClass.callApp.dwell == 5)
        #expect(MeetingSourceClass.chatApp.dwell == 30)
        #expect(MeetingSourceClass.browserCall.dwell == 8)
        #expect(MeetingSourceClass.browser.dwell == 60)
        #expect(MeetingSourceClass.otherApp.dwell == 60)
        #expect(MeetingSourceClass.callApp.rank < MeetingSourceClass.browserCall.rank)
        #expect(MeetingSourceClass.browserCall.rank < MeetingSourceClass.chatApp.rank)
        #expect(MeetingSourceClass.chatApp.rank < MeetingSourceClass.browser.rank)
        #expect(MeetingSourceClass.browser.rank < MeetingSourceClass.otherApp.rank)
    }
}
