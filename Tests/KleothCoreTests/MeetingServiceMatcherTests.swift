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
        #expect(id("Zoom Meeting") == "zoom")
        #expect(id("Zoom") == nil)
        #expect(id("Zoom Workplace") == nil)
        #expect(id("Home") == nil)
    }

    @Test func webexAndOthers() {
        #expect(id("Standup - Webex") == "webex")
        #expect(id("Meeting | Webex") == "webex")
        #expect(id("Meeting | Something") == nil)
        #expect(id("team-room – Whereby") == "whereby")
        #expect(id("team-room | Whereby") == "whereby")
        #expect(id("standup | Jitsi Meet") == "jitsi")
        #expect(id("Планёрка — Яндекс Телемост") == "telemost")
        #expect(id("Sync - Yandex Telemost") == "telemost")
        #expect(id("Планёрка — Контур.Толк") == "kontur-talk")
        #expect(id("Созвон — VK Звонки") == "vk-calls")
        #expect(id("Sync | VK Calls") == "vk-calls")
        #expect(id("Sync — SberJazz") == "jazz")
        #expect(id("Sync | Jazz by Sber") == "jazz")
        #expect(id("All That Jazz - YouTube") == nil)
    }

    /// Branch review (phase 2) M3: the service's name must END the title,
    /// after a separator and a head — its own call-window shape. A search
    /// page puts the query first and the engine last, so it never counts as a
    /// call (and its title is never stored); neither does a page that merely
    /// mentions the service, or its bare landing page.
    @Test func searchPagesAndMentionsNeverMatch() {
        let titles = [
            "whereby pricing - Google Search",
            "jitsi meet - Google Search",
            "Jitsi Meet self-hosting guide",
            "телемост — Яндекс: нашлось 3 млн результатов",
            "yandex telemost - Поиск в Google",
            "контур.толк — Яндекс: нашлось 120 тыс. результатов",
            "vk звонки - Google Search",
            "sberjazz at DuckDuckGo",
            "how to schedule a zoom meeting - Google Search",
            "Zoom Meeting tips and tricks",
            "How to Schedule a Zoom Meeting",
            "google meet - Google Search",
            "microsoft teams - Google Search",
            // Bare names: a landing page, not a call.
            "Whereby", "Jitsi Meet", "Телемост", "Яндекс Телемост", "Контур.Толк", "VK Звонки", "SberJazz",
            // The name first, a separator, then something else.
            "Контур.Толк — встреча", "SberJazz: Sync",
        ]
        for title in titles {
            #expect(id(title) == nil, "\(title)")
        }
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
