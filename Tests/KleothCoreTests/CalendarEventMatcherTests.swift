import Testing
import Foundation
@testable import KleothCore

@Suite struct CalendarEventMatcherTests {
    let t = Date(timeIntervalSince1970: 1_758_708_000)
    func c(_ title: String, start: TimeInterval, end: TimeInterval, allDay: Bool = false, cancelled: Bool = false,
           declined: Bool = false, others: Int = 0, link: String = "") -> CalendarCandidate {
        CalendarCandidate(title: title, start: t.addingTimeInterval(start), end: t.addingTimeInterval(end), isAllDay: allDay,
                          isCancelled: cancelled, declinedByUser: declined, otherAttendeeCount: others, linkText: link)
    }

    @Test func allDayCancelledAndDeclinedAreOut() {
        let out = [c("Day", start: -36000, end: 50000, allDay: true), c("Gone", start: -60, end: 1800, cancelled: true),
                   c("No", start: -60, end: 1800, declined: true, others: 3)]
        #expect(CalendarEventMatcher.best(out, at: t, serviceId: nil) == nil)
    }

    @Test func attendeesBeatASoloBlockAndAServiceLinkBeatsBoth() {
        let solo = c("Focus", start: -600, end: 3000)
        let sync = c("Weekly sync", start: -120, end: 1800, others: 4)
        let meet = c("Design review", start: 180, end: 1800, others: 2, link: "https://meet.google.com/abc-defg-hij")
        #expect(CalendarEventMatcher.best([solo, sync], at: t, serviceId: nil) == sync)
        #expect(CalendarEventMatcher.best([solo, sync, meet], at: t, serviceId: "google-meet") == meet)
        #expect(CalendarEventMatcher.best([solo, sync, meet], at: t, serviceId: "Google Meet") == meet)
        #expect(CalendarEventMatcher.best([solo, sync, meet], at: t, serviceId: "zoom") == sync)   // no zoom link: attendees tie → the closer start (sync, −120 s) wins
    }

    @Test func closestStartThenShorterWinsTies() {
        let far = c("A", start: -240, end: 3600, others: 1)
        let near = c("B", start: -30, end: 3600, others: 1)
        let nearShort = c("C", start: -30, end: 1800, others: 1)
        #expect(CalendarEventMatcher.best([far, near], at: t, serviceId: nil) == near)
        #expect(CalendarEventMatcher.best([near, nearShort], at: t, serviceId: nil) == nearShort)
    }

    @Test func onlyEventsOverlappingFiveMinutesCount() {
        let past = c("Earlier", start: -7200, end: -600, others: 2)
        let later = c("Later", start: 900, end: 3600, others: 2)
        let soon = c("Soon", start: 240, end: 3600, others: 2)
        #expect(CalendarEventMatcher.best([past, later], at: t, serviceId: nil) == nil)
        #expect(CalendarEventMatcher.best([past, later, soon], at: t, serviceId: nil) == soon)
        #expect(CalendarEventMatcher.best([], at: t, serviceId: nil) == nil)
    }

    /// Task 11 review, minor 3: a blank service is no service — "  " must not
    /// match the double space an empty location leaves in the link text.
    @Test func aBlankServiceIdIsNoService() {
        let solo = c("Focus", start: -60, end: 1800, link: "https://example.com  notes")
        let sync = c("Weekly sync", start: -120, end: 1800, others: 4)
        #expect(CalendarEventMatcher.best([solo, sync], at: t, serviceId: "  ") == sync)
        #expect(CalendarEventMatcher.best([solo, sync], at: t, serviceId: "") == sync)
        #expect(CalendarEventMatcher.best([solo, sync], at: t, serviceId: nil) == sync)
    }
}
