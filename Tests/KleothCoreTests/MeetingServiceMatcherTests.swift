import Testing
@testable import KleothCore

@Suite struct MeetingServiceMatcherTests {
    private func id(_ title: String) -> String? { MeetingServiceMatcher.match(windowTitle: title)?.id }

    @Test func googleMeet() {
        #expect(id("Meet - abc-defg-hij") == "google-meet")
        #expect(id("Meet – abc-defg-hij") == "google-meet")
        #expect(id("Weekly sync - Google Meet") == "google-meet")
        #expect(MeetingServiceMatcher.match(windowTitle: "Weekly sync - Google Meet")?.name == "Google Meet")
        #expect(id("Google Meet") == nil)
    }

    @Test func teams() {
        #expect(id("Weekly sync | Microsoft Teams") == "teams")
        #expect(id("Microsoft Teams") == nil)
        #expect(id("Chat | Microsoft Teams") == nil)
        #expect(id("Calendar | Microsoft Teams") == nil)
        #expect(id("Activity | Microsoft Teams") == nil)
    }

    @Test func zoom() {
        #expect(id("Anna's Zoom Meeting") == "zoom")
        #expect(id("Anna’s Zoom Meeting") == "zoom")
        #expect(id("Zoom Webinar") == "zoom")
        #expect(id("Zoom") == nil)
        #expect(id("Zoom Workplace") == nil)
        #expect(id("Home") == nil)
    }

    @Test func webexAndOthers() {
        #expect(id("Standup - Webex") == "webex")
        #expect(id("Meeting | Webex") == "webex")
        #expect(id("Meeting | Something") == nil)
        #expect(id("team-room – Whereby") == "whereby")
        #expect(id("Jitsi Meet") == "jitsi")
        #expect(id("Планёрка — Яндекс Телемост") == "telemost")
        #expect(id("Sync - Yandex Telemost") == "telemost")
        #expect(id("Контур.Толк — встреча") == "kontur-talk")
        #expect(id("VK Звонки") == "vk-calls")
        #expect(id("SberJazz: Sync") == "jazz")
        #expect(id("All That Jazz - YouTube") == nil)
    }

    /// Review M-6: every dash the code regex accepts works in the suffix too.
    @Test func googleMeetSuffixTakesAnyDash() {
        #expect(id("Weekly sync — Google Meet") == "google-meet")
        #expect(id("Meet — abc-defg-hij") == "google-meet")
    }

    @Test func plainTitlesCaseAndWhitespace() {
        #expect(id("GitHub - ofcRS/kleoth") == nil)
        #expect(id("") == nil)
        #expect(id("   ") == nil)
        #expect(id("  weekly sync - google meet  ") == "google-meet")
    }

    @Test func storedTitleIsCapped() {
        let long = String(repeating: "a", count: 300) + " - Google Meet"
        #expect(MeetingServiceMatcher.storedTitle(long).count == MeetingServiceMatcher.maxStoredTitleLength)
        #expect(MeetingServiceMatcher.storedTitle("short") == "short")
    }

    @Test func linkTokensAcceptIdOrName() {
        #expect(MeetingServiceMatcher.linkTokens(forService: "google-meet").contains("meet.google.com"))
        #expect(MeetingServiceMatcher.linkTokens(forService: "Google Meet").contains("meet.google.com"))
        #expect(MeetingServiceMatcher.linkTokens(forService: "Zoom").contains("zoom.us"))
        #expect(MeetingServiceMatcher.linkTokens(forService: "Teams").contains("teams.microsoft.com"))
        #expect(MeetingServiceMatcher.linkTokens(forService: "Slack") == ["slack"])
    }
}
