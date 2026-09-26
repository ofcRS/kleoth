import Testing
@testable import KleothCore

@Suite struct MeetingSourceTests {
    @Test func makeForAnApp() throws {
        let zoom = try #require(MeetingSource.make(bundleId: "us.zoom.xos", appName: "zoom.us", windowTitles: ["Zoom Meeting"], hasWebCall: false))
        #expect(zoom.key == "app:us.zoom.xos")
        #expect(zoom.name == "Zoom")
        #expect(zoom.sourceClass == .callApp)
        #expect(zoom.windowTitle == "Zoom Meeting")   // matched, kept
        #expect(zoom.offerSubject == "Zoom call")
        #expect(zoom.neverLabel == "Never for Zoom")
        let slack = try #require(MeetingSource.make(bundleId: "com.tinyspeck.slackmacgap", appName: "Slack", windowTitles: ["general - Acme - Slack"], hasWebCall: false))
        #expect(slack.windowTitle == nil)             // no meeting pattern → dropped, never stored
        #expect(slack.offerSubject == "Slack huddle")
    }

    @Test func makeBrowserWithMatchedTitleIsASiteCall() throws {
        let meet = try #require(MeetingSource.make(bundleId: "com.google.Chrome", appName: "Google Chrome", windowTitles: ["Inbox", "Weekly sync - Google Meet"], hasWebCall: true))
        #expect(meet.key == "site:google-meet")
        #expect(meet.name == "Google Meet")
        #expect(meet.sourceClass == .browserCall)
        #expect(meet.appBundleId == "com.google.Chrome")
        #expect(meet.windowTitle == "Weekly sync - Google Meet")
        #expect(meet.offerSubject == "Google Meet call")
        #expect(meet.neverLabel == "Never for Google Meet")
    }

    @Test func makeBrowserWithOnlyAWebCallAssertion() throws {
        let call = try #require(MeetingSource.make(bundleId: "com.google.Chrome", appName: "Google Chrome", windowTitles: ["Some page"], hasWebCall: true))
        #expect(call.key == "webcall:com.google.Chrome")
        #expect(call.sourceClass == .browserCall)
        #expect(call.windowTitle == nil)
        #expect(call.offerSubject == "Call in Chrome")
        #expect(call.neverLabel == "Never for calls in Chrome")
    }

    @Test func makeBrowserWithoutCallUsesBrowserKey() throws {
        let browser = try #require(MeetingSource.make(bundleId: "com.google.Chrome", appName: "Google Chrome", windowTitles: ["Docs"], hasWebCall: false))
        #expect(browser.key == "browser:com.google.Chrome")
        #expect(browser.sourceClass == .browser)
        #expect(browser.offerSubject == "Chrome is using the mic")
        #expect(browser.neverLabel == "Never for Chrome")
    }

    @Test func neverClassIsNil() {
        #expect(MeetingSource.make(bundleId: "com.electron.wispr-flow", appName: "Wispr Flow", windowTitles: [], hasWebCall: false) == nil)
    }

    @Test func offerText() throws {
        let zoom = try #require(MeetingSource.make(bundleId: "us.zoom.xos", appName: "zoom.us", windowTitles: [], hasWebCall: false))
        #expect(MeetingOfferText.offer(for: zoom, calendarTitle: nil) == "Zoom call — record it?")
        #expect(MeetingOfferText.offer(for: zoom, calendarTitle: "Weekly sync") == "“Weekly sync” on Zoom — record it?")
        let long = String(repeating: "x", count: 60)
        #expect(MeetingOfferText.offer(for: zoom, calendarTitle: long) == "“\(String(repeating: "x", count: 40))…” on Zoom — record it?")
        #expect(MeetingOfferText.stop(for: zoom) == "Zoom released the mic — stop recording?")
        let other = try #require(MeetingSource.make(bundleId: "com.example.x", appName: "Telemost", windowTitles: [], hasWebCall: false))
        #expect(MeetingOfferText.offer(for: other, calendarTitle: nil) == "Telemost is using the mic — record it?")
    }
}
