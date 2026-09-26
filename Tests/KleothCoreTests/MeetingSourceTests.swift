import Foundation
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

    /// Branch review (phase 2) M7: the calendar event on now names a call —
    /// a call app, a `site:` or `webcall:` browser call, or a chat app (a
    /// huddle: chat apps are offered only after a 30 s hold). Voice typing in
    /// a browser during "Focus time" is not that event, nor is an unknown app.
    @Test func offerNamesTheCalendarEventForCallsAndHuddlesOnly() throws {
        let zoom = try #require(MeetingSource.make(bundleId: "us.zoom.xos", appName: "zoom.us", windowTitles: [], hasWebCall: false))
        let meet = try #require(MeetingSource.make(bundleId: "com.google.Chrome", appName: "Google Chrome",
                                                   windowTitles: ["Weekly sync - Google Meet"], hasWebCall: false))
        let webCall = try #require(MeetingSource.make(bundleId: "com.google.Chrome", appName: "Google Chrome", windowTitles: [], hasWebCall: true))
        let browser = try #require(MeetingSource.make(bundleId: "com.google.Chrome", appName: "Google Chrome", windowTitles: [], hasWebCall: false))
        let chat = try #require(MeetingSource.make(bundleId: "ru.keepcoder.Telegram", appName: "Telegram", windowTitles: [], hasWebCall: false))
        let other = try #require(MeetingSource.make(bundleId: "com.example.x", appName: "Telemost", windowTitles: [], hasWebCall: false))

        #expect(MeetingOfferText.namesCalendarEvent(for: zoom))
        #expect(MeetingOfferText.namesCalendarEvent(for: meet))
        #expect(MeetingOfferText.namesCalendarEvent(for: webCall))
        #expect(!MeetingOfferText.namesCalendarEvent(for: browser))
        #expect(MeetingOfferText.namesCalendarEvent(for: chat))   // a huddle: offered only after a 30 s hold
        #expect(!MeetingOfferText.namesCalendarEvent(for: other))

        #expect(MeetingOfferText.offer(for: meet, calendarTitle: "Weekly sync") == "“Weekly sync” on Google Meet — record it?")
        #expect(MeetingOfferText.offer(for: webCall, calendarTitle: "Weekly sync") == "“Weekly sync” on Chrome — record it?")
        #expect(MeetingOfferText.offer(for: browser, calendarTitle: "Focus time") == "Chrome is using the mic — record it?")
        #expect(MeetingOfferText.offer(for: chat, calendarTitle: "Weekly sync") == "“Weekly sync” on Telegram — record it?")
        #expect(MeetingOfferText.offer(for: chat, calendarTitle: nil) == "Telegram call — record it?")
        #expect(MeetingOfferText.offer(for: other, calendarTitle: "Focus time") == "Telemost is using the mic — record it?")
    }

    @Test func aChatAppNamesOnlyAnEventThatLooksLikeACall() throws {
        let chat = try #require(MeetingSource.make(bundleId: "ru.keepcoder.Telegram", appName: "Telegram", windowTitles: [], hasWebCall: false))
        let zoom = try #require(MeetingSource.make(bundleId: "us.zoom.xos", appName: "zoom.us", windowTitles: [], hasWebCall: false))
        let at = Date(timeIntervalSince1970: 1_000_000)
        func event(_ title: String, others: Int, link: String) -> CalendarCandidate {
            CalendarCandidate(title: title, start: at, end: at.addingTimeInterval(1800), isAllDay: false, isCancelled: false,
                              declinedByUser: false, otherAttendeeCount: others, linkText: link)
        }
        // A voice note during a solo block is not named after it; a huddle in a real meeting is.
        #expect(MeetingOfferText.calendarTitle(for: chat, event: event("Focus time", others: 0, link: "")) == nil)
        #expect(MeetingOfferText.calendarTitle(for: chat, event: event("Weekly sync", others: 2, link: "")) == "Weekly sync")
        #expect(MeetingOfferText.calendarTitle(for: chat, event: event("Standup", others: 0, link: "https://app.slack.com/huddle/T1/C2")) == "Standup")
        // A call app names any event on now.
        #expect(MeetingOfferText.calendarTitle(for: zoom, event: event("Focus time", others: 0, link: "")) == "Focus time")
        #expect(MeetingOfferText.calendarTitle(for: zoom, event: nil) == nil)
    }
}
