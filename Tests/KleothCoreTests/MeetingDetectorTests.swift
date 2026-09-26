import Testing
import Foundation
@testable import KleothCore

/// The call-detection machine (design §3.2, §4.1, §6). `handle` is TOTAL; every
/// effect is the host's only instruction; time is whatever the events say.
@Suite struct MeetingDetectorTests {
    let t0 = Date(timeIntervalSince1970: 1_758_800_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    let zoom = MeetingSource.make(bundleId: "us.zoom.xos", appName: "zoom.us", windowTitles: [], hasWebCall: false)!
    let slack = MeetingSource.make(bundleId: "com.tinyspeck.slackmacgap", appName: "Slack", windowTitles: [], hasWebCall: false)!
    let chrome = MeetingSource.make(bundleId: "com.google.Chrome", appName: "Google Chrome", windowTitles: ["Docs"], hasWebCall: false)!
    let chromeCall = MeetingSource.make(bundleId: "com.google.Chrome", appName: "Google Chrome", windowTitles: ["Docs"], hasWebCall: true)!
    let meet = MeetingSource.make(bundleId: "com.google.Chrome", appName: "Google Chrome", windowTitles: ["Sync - Google Meet"], hasWebCall: true)!
    let other = MeetingSource.make(bundleId: "com.example.game", appName: "Game", windowTitles: [], hasWebCall: false)!

    /// A detector with offers on, fed by a plain `observed` every `step` seconds.
    func detector(on: Bool = true) -> MeetingDetector {
        var d = MeetingDetector()
        _ = d.handle(.environment(MeetingDetector.Environment(offersEnabled: on), at: t0))
        return d
    }

    /// Observes `sources` at every second from `from` to `to` (inclusive) and
    /// returns every effect, in order.
    func run(_ d: inout MeetingDetector, _ sources: Set<MeetingSource>, from: TimeInterval, to: TimeInterval) -> [MeetingDetector.Effect] {
        var out: [MeetingDetector.Effect] = []
        var s = from
        while s <= to { out += d.handle(.observed(sources, at: at(s))); s += 1 }
        return out
    }

    func shownOffer(_ effects: [MeetingDetector.Effect]) -> MeetingDetector.Offer? {
        for e in effects { if case .show(let o) = e { return o } }
        return nil
    }

    // MARK: - Dwell

    @Test func callAppOfferedAtFiveSecondsNotBefore() {
        var d = detector()
        #expect(run(&d, [zoom], from: 0, to: 4).isEmpty)
        #expect(d.handle(.observed([zoom], at: at(4.9))).isEmpty)
        let effects = d.handle(.observed([zoom], at: at(5)))
        let offer = shownOffer(effects)
        #expect(offer?.kind == .start)
        #expect(offer?.source == zoom)
        #expect(offer?.id == "offer-1")
        #expect(d.visibleOffer == offer)
    }

    @Test func chatAppAtThirtyBrowserCallAtEightOthersAtSixty() {
        var d = detector()
        #expect(run(&d, [slack], from: 0, to: 29).isEmpty)
        #expect(shownOffer(d.handle(.observed([slack], at: at(30))))?.source == slack)

        var e = detector()
        #expect(run(&e, [chromeCall], from: 0, to: 7).isEmpty)
        #expect(shownOffer(e.handle(.observed([chromeCall], at: at(8))))?.source == chromeCall)

        var f = detector()
        #expect(run(&f, [chrome], from: 0, to: 59).isEmpty)
        #expect(shownOffer(f.handle(.observed([chrome], at: at(60))))?.source == chrome)

        var g = detector()
        #expect(run(&g, [other], from: 0, to: 59).isEmpty)
        #expect(shownOffer(g.handle(.observed([other], at: at(60))))?.source == other)
    }

    @Test func browserGainingAWebCallMidDwellKeepsItsStart() {
        var d = detector()
        #expect(run(&d, [chrome], from: 0, to: 5).isEmpty)
        // At 6 s the assertion appears: browser call, dwell 8 s from the START (0), so due at 8.
        #expect(d.handle(.observed([chromeCall], at: at(6))).isEmpty)
        #expect(d.handle(.observed([chromeCall], at: at(7))).isEmpty)
        #expect(shownOffer(d.handle(.observed([chromeCall], at: at(8))))?.source == chromeCall)
    }

    @Test func classNeverGoesDown() {
        var d = detector()
        _ = run(&d, [meet], from: 0, to: 3)
        // The Meet tab is switched away: the title is gone, the assertion too.
        _ = d.handle(.observed([chrome], at: at(4)))
        let offer = shownOffer(run(&d, [chrome], from: 5, to: 8))
        #expect(offer?.source.key == "site:google-meet")
    }

    // MARK: - Sessions and gaps

    @Test func sevenSecondGapKeepsTheSessionEightEndsIt() {
        var d = detector()
        _ = run(&d, [slack], from: 0, to: 10)
        _ = run(&d, [], from: 11, to: 17)                  // 7 s gap
        _ = run(&d, [slack], from: 18, to: 29)
        #expect(shownOffer(d.handle(.observed([slack], at: at(30))))?.source == slack)   // dwell from 0

        var e = detector()
        _ = run(&e, [slack], from: 0, to: 10)
        _ = run(&e, [], from: 11, to: 19)                  // 9 s gap → ended
        #expect(run(&e, [slack], from: 20, to: 49).isEmpty)
        #expect(shownOffer(e.handle(.observed([slack], at: at(50))))?.source == slack)   // new session from 20
    }

    @Test func releaseWithdrawsAVisibleOfferAfterTheGrace() throws {
        var d = detector()
        let offer = try #require(shownOffer(run(&d, [zoom], from: 0, to: 5)))
        #expect(run(&d, [], from: 6, to: 12).isEmpty)       // 7 s: still held for the machine
        #expect(d.handle(.observed([], at: at(14))) == [.withdraw(offerId: offer.id)])
        #expect(d.visibleOffer == nil)
    }

    // MARK: - Answers

    @Test func dismissSilencesTheSessionAndTheSourceForTenMinutes() throws {
        var d = detector()
        let offer = try #require(shownOffer(run(&d, [zoom], from: 0, to: 5)))
        #expect(d.handle(.answered(offerId: offer.id, .dismissed, at: at(6))).isEmpty)
        #expect(run(&d, [zoom], from: 7, to: 60).isEmpty)                    // same session
        _ = run(&d, [], from: 61, to: 70)                                    // ended
        #expect(run(&d, [zoom], from: 100, to: 200).isEmpty)                 // inside 10 min of the ✕
        _ = run(&d, [], from: 201, to: 210)
        #expect(shownOffer(run(&d, [zoom], from: 700, to: 705)) != nil)     // after 10 min
    }

    @Test func neverEmitsIgnoreAndAnIgnoredKeyIsNeverOffered() throws {
        var d = detector()
        let offer = try #require(shownOffer(run(&d, [zoom], from: 0, to: 5)))
        #expect(d.handle(.answered(offerId: offer.id, .never, at: at(6))) == [.ignore(key: "app:us.zoom.xos", name: "Zoom")])
        _ = run(&d, [], from: 7, to: 20)
        #expect(run(&d, [zoom], from: 1000, to: 1010).isEmpty)
        // The host persists it and hands it back through the environment too.
        _ = d.handle(.environment(MeetingDetector.Environment(offersEnabled: true, ignoredKeys: ["app:us.zoom.xos"]), at: at(1011)))
        #expect(run(&d, [zoom], from: 2000, to: 2010).isEmpty)
    }

    @Test func neverForBrowserKeepsSiteCallsOffered() throws {
        var d = detector()
        let offer = try #require(shownOffer(run(&d, [chrome], from: 0, to: 60)))
        #expect(offer.source.key == "browser:com.google.Chrome")
        #expect(d.handle(.answered(offerId: offer.id, .never, at: at(61))) == [.ignore(key: "browser:com.google.Chrome", name: "Chrome")])
        _ = run(&d, [], from: 62, to: 75)
        let meetOffer = shownOffer(run(&d, [meet], from: 800, to: 808))
        #expect(meetOffer?.source.key == "site:google-meet")
    }

    @Test func refusedRetriesAfterOneSecondDisplacedComesBackFresh() throws {
        var d = detector()
        let offer = try #require(shownOffer(run(&d, [zoom], from: 0, to: 5)))
        #expect(d.handle(.answered(offerId: offer.id, .refused, at: at(5))).isEmpty)
        #expect(d.nextDeadline == at(6))
        #expect(d.handle(.tick(at: at(5.5), pointerOnPill: false)).isEmpty)
        let again = try #require(shownOffer(d.handle(.tick(at: at(6), pointerOnPill: false))))
        #expect(again.id == "offer-2")
        #expect(d.handle(.answered(offerId: again.id, .displaced, at: at(7))).isEmpty)
        let third = try #require(shownOffer(d.handle(.tick(at: at(8), pointerOnPill: false))))
        #expect(third.source == zoom)
        #expect(d.nextDeadline == at(8 + MeetingDetectionDefaults.offerLifetime))
    }

    // MARK: - Lifetime

    @Test func offerExpiresAtThirtySecondsDeferredByHover() throws {
        var d = detector()
        let offer = try #require(shownOffer(run(&d, [zoom], from: 0, to: 5)))
        #expect(d.nextDeadline == at(35))
        #expect(d.handle(.tick(at: at(34), pointerOnPill: false)).isEmpty)
        #expect(d.handle(.tick(at: at(35), pointerOnPill: false)) == [.withdraw(offerId: offer.id)])
        #expect(run(&d, [zoom], from: 36, to: 100).isEmpty)   // silenced for the session

        var e = detector()
        let o2 = try #require(shownOffer(run(&e, [zoom], from: 0, to: 5)))
        #expect(e.handle(.tick(at: at(34), pointerOnPill: true)).isEmpty)
        #expect(e.handle(.tick(at: at(40), pointerOnPill: true)).isEmpty)       // held while hovered
        #expect(e.handle(.tick(at: at(41), pointerOnPill: false)).isEmpty)      // deadline → 46
        #expect(e.nextDeadline == at(46))
        #expect(e.handle(.tick(at: at(46), pointerOnPill: false)) == [.withdraw(offerId: o2.id)])
    }

    // MARK: - Suppression

    @Test func eachSuppressionBlocksAndWithdraws() throws {
        for env in [
            MeetingDetector.Environment(offersEnabled: false),
            MeetingDetector.Environment(offersEnabled: true, pillHidden: true),
            MeetingDetector.Environment(offersEnabled: true, screenRecording: true),
            MeetingDetector.Environment(offersEnabled: true, meetingSince: Date(timeIntervalSince1970: 1_758_800_003)),
        ] {
            var d = detector()
            let offer = try #require(shownOffer(run(&d, [zoom], from: 0, to: 5)))
            #expect(d.handle(.environment(env, at: at(6))) == [.withdraw(offerId: offer.id)])
            #expect(run(&d, [zoom], from: 7, to: 30).isEmpty)
        }
    }

    @Test func aSessionOlderThanTenMinutesWhenSuppressionLiftsIsNeverOffered() {
        var d = detector(on: false)
        _ = run(&d, [zoom], from: 0, to: 601)
        _ = d.handle(.environment(MeetingDetector.Environment(offersEnabled: true), at: at(602)))
        #expect(run(&d, [zoom], from: 603, to: 700).isEmpty)

        var e = detector(on: false)
        _ = run(&e, [zoom], from: 0, to: 100)
        #expect(shownOffer(e.handle(.environment(MeetingDetector.Environment(offersEnabled: true), at: at(101)))) != nil)   // dwell long passed
    }

    // MARK: - Several sources

    @Test func classPriorityThenEarliestSession() throws {
        var d = detector(on: false)
        _ = run(&d, [slack], from: 0, to: 40)             // slack first, long past its dwell
        _ = run(&d, [slack, zoom], from: 41, to: 50)      // zoom past its 5 s
        let first = try #require(shownOffer(d.handle(.environment(MeetingDetector.Environment(offersEnabled: true), at: at(51)))))
        #expect(first.source == zoom)                     // call app outranks the older chat session
        let second = try #require(shownOffer(d.handle(.answered(offerId: first.id, .dismissed, at: at(53)))))
        #expect(second.source == slack)                   // after a ✕ the next due source may be offered

        var e = detector()
        _ = run(&e, [slack], from: 0, to: 2)
        let tie = try #require(shownOffer(run(&e, [slack, other], from: 3, to: 62)))
        #expect(tie.source == slack)                      // both due; class first (chat > other)
    }

    // MARK: - Linking and the stop suggestion

    @Test func acceptedOfferLinksItsSourceAndStopIsSuggestedTwentySecondsAfterRelease() throws {
        var d = detector()
        let offer = try #require(shownOffer(run(&d, [zoom], from: 0, to: 5)))
        _ = d.handle(.answered(offerId: offer.id, .accepted, at: at(6)))
        _ = d.handle(.environment(MeetingDetector.Environment(offersEnabled: true, meetingSince: at(7)), at: at(7)))
        #expect(d.linkedSource == zoom)
        _ = run(&d, [zoom], from: 8, to: 100)
        _ = run(&d, [], from: 101, to: 119)               // released at 101
        #expect(d.handle(.observed([], at: at(120))).isEmpty)
        let stop = try #require(shownOffer(d.handle(.observed([], at: at(121)))))
        #expect(stop.kind == .stop)
        #expect(stop.source == zoom)
        #expect(d.nextDeadline == at(121 + MeetingDetectionDefaults.stopOfferLifetime))
        // Ignored: it expires, and no second suggestion for the same release.
        #expect(d.handle(.tick(at: at(181), pointerOnPill: false)) == [.withdraw(offerId: stop.id)])
        #expect(run(&d, [], from: 182, to: 400).isEmpty)
    }

    @Test func stopSuggestionWithdrawnOnReacquireAndOnMeetingStop() throws {
        var d = detector()
        _ = d.handle(.environment(MeetingDetector.Environment(offersEnabled: true, meetingSince: at(0)), at: at(0)))
        _ = run(&d, [zoom], from: 1, to: 10)               // first source to appear links
        #expect(d.linkedSource == zoom)
        _ = run(&d, [], from: 11, to: 30)
        let stop = try #require(shownOffer(d.handle(.observed([], at: at(31)))))
        #expect(d.handle(.observed([zoom], at: at(32))) == [.withdraw(offerId: stop.id)])   // rejoined
        _ = run(&d, [], from: 33, to: 52)
        let stop2 = try #require(shownOffer(d.handle(.observed([], at: at(53)))))          // a new release
        #expect(d.handle(.environment(MeetingDetector.Environment(offersEnabled: true), at: at(54))) == [.withdraw(offerId: stop2.id)])
    }

    /// Controller ruling (pre-flight M-9): with call detection off, a meeting
    /// is never asked "stop recording?" — the link (and the context) still work.
    @Test func noStopSuggestionWhileCallDetectionIsOff() {
        var d = detector(on: false)
        _ = d.handle(.environment(MeetingDetector.Environment(offersEnabled: false, meetingSince: at(0)), at: at(0)))
        _ = run(&d, [zoom], from: 1, to: 10)
        #expect(d.linkedSource == zoom)
        #expect(run(&d, [], from: 11, to: 200).isEmpty)    // released at 11: long past the 20 s grace
        #expect(d.visibleOffer == nil)
        #expect(d.nextDeadline == nil)                      // no tick asked for a suggestion that cannot come
    }

    /// Controller ruling (review M-2): detection switched off withdraws a stop
    /// suggestion already up; switching it back on does not repeat it.
    @Test func turningDetectionOffWithdrawsAVisibleStopSuggestion() throws {
        var d = detector()
        _ = d.handle(.environment(MeetingDetector.Environment(offersEnabled: true, meetingSince: at(0)), at: at(0)))
        _ = run(&d, [zoom], from: 1, to: 10)
        _ = run(&d, [], from: 11, to: 30)
        let stop = try #require(shownOffer(d.handle(.observed([], at: at(31)))))
        #expect(d.handle(.environment(MeetingDetector.Environment(offersEnabled: false, meetingSince: at(0)), at: at(32)))
                == [.withdraw(offerId: stop.id)])
        #expect(d.visibleOffer == nil)
        #expect(d.nextDeadline == nil)
        #expect(d.handle(.environment(MeetingDetector.Environment(offersEnabled: true, meetingSince: at(0)), at: at(40))).isEmpty)
        #expect(run(&d, [], from: 41, to: 120).isEmpty)          // once per release
    }

    /// Review M-3: a new meeting straight after another (no nil in between)
    /// withdraws the old meeting's stop suggestion — accepting it would stop the new one.
    @Test func aNewMeetingWithdrawsTheOldMeetingsStopSuggestion() throws {
        var d = detector()
        _ = d.handle(.environment(MeetingDetector.Environment(offersEnabled: true, meetingSince: at(0)), at: at(0)))
        _ = run(&d, [zoom], from: 1, to: 10)
        _ = run(&d, [], from: 11, to: 30)
        let stop = try #require(shownOffer(d.handle(.observed([], at: at(31)))))
        #expect(d.handle(.environment(MeetingDetector.Environment(offersEnabled: true, meetingSince: at(40)), at: at(40)))
                == [.withdraw(offerId: stop.id)])
        #expect(d.visibleOffer == nil)
        #expect(d.linkedSource == nil)
    }

    /// Controller ruling (review M-4): when a recorded meeting ends, the calls
    /// held during it are not offered again ("the user evidently chose") —
    /// a NEW session of the same app is.
    @Test func aCallHeldDuringARecordedMeetingIsNotOfferedWhenTheMeetingEnds() throws {
        var d = detector()
        _ = run(&d, [zoom], from: 0, to: 3)
        _ = d.handle(.environment(MeetingDetector.Environment(offersEnabled: true, meetingSince: at(4)), at: at(4)))   // hotkey, before the offer
        _ = run(&d, [zoom], from: 5, to: 300)
        #expect(d.handle(.environment(MeetingDetector.Environment(offersEnabled: true), at: at(301))).isEmpty)
        #expect(run(&d, [zoom], from: 302, to: 500).isEmpty)
        #expect(settles(&d, at: 500))
        _ = run(&d, [], from: 501, to: 520)                                    // Zoom leaves; the session ends
        #expect(shownOffer(run(&d, [zoom], from: 600, to: 605))?.source == zoom)   // a new call is offered

        // An offer withdrawn by a hotkey start is not re-offered at the meeting's end either.
        var e = detector()
        let offer = try #require(shownOffer(run(&e, [zoom], from: 0, to: 6)))
        #expect(e.handle(.environment(MeetingDetector.Environment(offersEnabled: true, meetingSince: at(7)), at: at(7)))
                == [.withdraw(offerId: offer.id)])
        _ = run(&e, [zoom], from: 8, to: 300)
        #expect(e.handle(.environment(MeetingDetector.Environment(offersEnabled: true), at: at(301))).isEmpty)
        #expect(run(&e, [zoom], from: 302, to: 400).isEmpty)
    }

    @Test func relinksToAnotherCallClassSourceInsteadOfSuggestingStop() {
        var d = detector()
        _ = d.handle(.environment(MeetingDetector.Environment(offersEnabled: true, meetingSince: at(0)), at: at(0)))
        _ = run(&d, [slack], from: 1, to: 10)
        #expect(d.linkedSource == slack)
        _ = run(&d, [slack, zoom], from: 11, to: 20)
        #expect(run(&d, [zoom], from: 21, to: 60).isEmpty)  // the huddle moved to Zoom: no stop offer
        #expect(d.linkedSource == zoom)
    }

    @Test func aMeetingsLastStretchIsCountedWhenItEnds() {
        // The mic seconds up to the stop count even with no observation since
        // the last one: the end accrues while the meeting is still current.
        var d = detector()
        _ = d.handle(.environment(MeetingDetector.Environment(offersEnabled: true, meetingSince: at(0)), at: at(0)))
        _ = run(&d, [zoom], from: 0, to: 5)
        _ = d.handle(.environment(MeetingDetector.Environment(offersEnabled: true), at: at(30)))
        #expect((d.meetingSource(at: at(30))?.micSeconds ?? 0) >= 29)
    }

    @Test func meetingSourceIsTheLongestHolderOverTwentySecondsElseTheLinked() {
        var d = detector()
        _ = d.handle(.environment(MeetingDetector.Environment(offersEnabled: true, meetingSince: at(0)), at: at(0)))
        _ = run(&d, [zoom], from: 0, to: 5)                 // linked, 5 s
        _ = run(&d, [zoom, slack], from: 6, to: 10)
        _ = run(&d, [slack], from: 11, to: 40)              // slack ≈ 34 s
        let source = d.meetingSource(at: at(40))
        #expect(source?.source == slack)
        #expect((source?.micSeconds ?? 0) >= 30)

        var e = detector()
        _ = e.handle(.environment(MeetingDetector.Environment(offersEnabled: true, meetingSince: at(0)), at: at(0)))
        _ = run(&e, [zoom], from: 0, to: 10)
        let short = e.meetingSource(at: at(12))
        #expect(short?.source == zoom)                       // linked, under 20 s
        #expect((short?.micSeconds ?? -1) >= 10 && (short?.micSeconds ?? 99) <= 12)

        #expect(MeetingDetector().meetingSource(at: at(0)) == nil)
    }

    @Test func nextDeadlineIsTheEarliestPendingOrNil() {
        var d = detector()
        #expect(d.nextDeadline == nil)
        _ = d.handle(.observed([slack], at: at(0)))
        #expect(d.nextDeadline == at(30))                    // slack's dwell
        _ = d.handle(.observed([slack, zoom], at: at(1)))
        #expect(d.nextDeadline == at(6))                     // zoom's dwell is sooner
        _ = d.handle(.observed([slack], at: at(2)))          // zoom released → grace at 10
        #expect(d.nextDeadline == at(10))
        _ = run(&d, [], from: 3, to: 12)
        _ = run(&d, [], from: 13, to: 40)                    // everything ended (slack at 10 + 8)
        #expect(d.nextDeadline == nil)
    }

    // MARK: - Deterministic choices (review M-1)

    let teams = MeetingSource.make(bundleId: "com.microsoft.teams2", appName: "Microsoft Teams", windowTitles: [], hasWebCall: false)!

    /// The same sources in sets of different capacities — different iteration
    /// orders, so a choice left to Set/Dictionary order shows up as a mismatch.
    func batches(_ sources: [MeetingSource]) -> [Set<MeetingSource>] {
        [1, 2, 4, 8, 16, 32, 64, 128, 256, 512].flatMap { capacity -> [Set<MeetingSource>] in
            var forward = Set<MeetingSource>(minimumCapacity: capacity)
            var backward = Set<MeetingSource>(minimumCapacity: capacity)
            for s in sources { forward.insert(s) }
            for s in sources.reversed() { backward.insert(s) }
            return [forward, backward]
        }
    }

    @Test func aBatchLinksByClassNotByIterationOrder() {
        for batch in batches([chrome, other, zoom]) {
            var d = detector()
            _ = d.handle(.environment(MeetingDetector.Environment(offersEnabled: true, meetingSince: at(0)), at: at(0)))
            _ = d.handle(.observed(batch, at: at(1)))
            #expect(d.linkedSource == zoom)
        }
    }

    @Test func aMeetingStartLinksByClassThenStartThenKey() {
        for batch in batches([zoom, teams]) {
            var d = detector(on: false)
            _ = d.handle(.observed(batch, at: at(0)))
            _ = d.handle(.environment(MeetingDetector.Environment(offersEnabled: true, meetingSince: at(1)), at: at(1)))
            #expect(d.linkedSource == teams)            // same class, same start: "app:com.microsoft.teams2" < "app:us.zoom.xos"
        }
    }

    @Test func theRelinkTargetIsTheBestOtherCall() {
        for batch in batches([slack, zoom, teams]) {
            var d = detector()
            _ = d.handle(.environment(MeetingDetector.Environment(offersEnabled: true, meetingSince: at(0)), at: at(0)))
            _ = run(&d, [slack], from: 1, to: 3)
            _ = d.handle(.observed(batch, at: at(4)))
            _ = run(&d, [zoom, teams], from: 5, to: 9)
            #expect(d.linkedSource == teams)            // both call apps from 4: the key decides
        }
        for batch in batches([meet, zoom]) {
            var d = detector()
            _ = d.handle(.environment(MeetingDetector.Environment(offersEnabled: true, meetingSince: at(0)), at: at(0)))
            _ = run(&d, [slack], from: 1, to: 3)
            _ = run(&d, [slack, meet], from: 4, to: 5)
            _ = d.handle(.observed(batch.union([slack]), at: at(6)))
            _ = run(&d, [meet, zoom], from: 7, to: 9)
            #expect(d.linkedSource == zoom)             // a call app outranks the older browser call
        }
    }

    @Test func dueOffersAndMeetingSourceTiesAreDeterministic() {
        for batch in batches([zoom, teams]) {
            var d = detector()
            let offer = shownOffer(run(&d, batch, from: 0, to: 5))
            #expect(offer?.source == teams)             // both due at 5, same class and start
        }
        for batch in batches([chrome, zoom]) {
            var d = detector()
            _ = d.handle(.environment(MeetingDetector.Environment(offersEnabled: true, meetingSince: at(0)), at: at(0)))
            _ = run(&d, batch, from: 0, to: 40)
            #expect(d.meetingSource(at: at(40))?.source == zoom)   // equal seconds: the call app
        }
    }

    // MARK: - Deadlines are never in the past (review C-1)

    /// The host: tick at `s` while a deadline has come due. True when the
    /// machine settles (nil or a future deadline) within three ticks — more
    /// is the main-actor hot loop.
    func settles(_ d: inout MeetingDetector, at s: TimeInterval, pointerOnPill: Bool = false) -> Bool {
        for _ in 0..<3 {
            guard let deadline = d.nextDeadline, deadline <= at(s) else { return true }
            _ = d.handle(.tick(at: at(s), pointerOnPill: pointerOnPill))
        }
        return d.nextDeadline.map { $0 > at(s) } ?? true
    }

    @Test func aMeetingStoppedMidCallAfterTenMinutesLeavesNoPastDeadline() {
        var d = detector()
        _ = run(&d, [zoom], from: 0, to: 3)
        _ = d.handle(.environment(MeetingDetector.Environment(offersEnabled: true, meetingSince: at(4)), at: at(4)))   // hotkey, before the offer
        _ = run(&d, [zoom], from: 5, to: 700)
        _ = d.handle(.environment(MeetingDetector.Environment(offersEnabled: true), at: at(701)))   // stopped; Zoom still in the call
        #expect(settles(&d, at: 701))
        #expect(run(&d, [zoom], from: 702, to: 1000).isEmpty)
        #expect(settles(&d, at: 1000))
    }

    @Test func detectionSwitchedOnDuringALongCallLeavesNoPastDeadline() {
        var d = detector(on: false)
        _ = run(&d, [zoom], from: 0, to: 700)
        #expect(d.handle(.environment(MeetingDetector.Environment(offersEnabled: true), at: at(701))).isEmpty)
        #expect(settles(&d, at: 701))
    }

    @Test func hoveringPastTheDeadlineKeepsTheOfferWithAFutureDeadline() throws {
        var d = detector()
        let offer = try #require(shownOffer(run(&d, [zoom], from: 0, to: 5)))   // deadline 35
        #expect(d.handle(.tick(at: at(30), pointerOnPill: true)).isEmpty)
        #expect(settles(&d, at: 36, pointerOnPill: true))
        #expect(d.visibleOffer == offer)                                         // held while hovered
        #expect(settles(&d, at: 120, pointerOnPill: true))
        #expect(d.visibleOffer == offer)
    }

    @Test func aPillThatRefusesForTenMinutesLeavesNoPastDeadline() {
        var d = detector()
        var s: TimeInterval = 0
        while s <= 620 {
            _ = d.handle(.observed([zoom], at: at(s)))
            if let o = d.visibleOffer { _ = d.handle(.answered(offerId: o.id, .refused, at: at(s))) }
            #expect(settles(&d, at: s), "at \(s)")
            if let o = d.visibleOffer { _ = d.handle(.answered(offerId: o.id, .refused, at: at(s))) }
            s += 1
        }
        #expect(run(&d, [zoom], from: 621, to: 700).isEmpty)   // too old to offer now
        #expect(settles(&d, at: 700))
    }
}
