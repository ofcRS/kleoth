import Testing
import Foundation
@testable import KleothCore

/// Pre-flight I-3 / review C-1 regression guard: a past `nextDeadline` would be
/// a hot loop in the host (which ticks at every deadline that has come due).
@Suite struct MeetingDetectorDeadlineTests {
    /// The host ticks at `nextDeadline`; after a `.tick(at: now)` the machine
    /// must never ask for a tick at or before `now` (a past deadline = a hot loop).
    ///
    /// The runs are long enough to reach the risky paths: calls held for many
    /// minutes (past `maxOfferAge` and `dismissCooldown`, both 600 s), the
    /// pointer resting on the pill, "never" keys, every answer and every
    /// suppression. The seed is fixed, so a failure is reproducible.
    @Test func nextDeadlineIsNeverDueAfterATick() {
        let t0 = Date(timeIntervalSince1970: 1_758_800_000)
        let pool: [MeetingSource] = [
            MeetingSource.make(bundleId: "us.zoom.xos", appName: "zoom.us", windowTitles: [], hasWebCall: false)!,
            MeetingSource.make(bundleId: "com.tinyspeck.slackmacgap", appName: "Slack", windowTitles: [], hasWebCall: false)!,
            MeetingSource.make(bundleId: "com.google.Chrome", appName: "Google Chrome", windowTitles: ["Docs"], hasWebCall: false)!,
            MeetingSource.make(bundleId: "com.example.game", appName: "Game", windowTitles: [], hasWebCall: false)!,
        ]
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        for run in 0..<120 {
            var d = MeetingDetector()
            var now: TimeInterval = 0
            var held = Set<MeetingSource>()
            var env = MeetingDetector.Environment(offersEnabled: true)
            var hover = false
            _ = d.handle(.environment(env, at: t0))
            for step in 0..<1500 {                          // ≈ 2,600 s a run
                now += Double(next(6) + 1) * 0.5
                let date = t0.addingTimeInterval(now)
                switch next(40) {
                case 0:                                     // a source comes or goes (held ≈ 70 s on average, often far longer)
                    let s = pool[next(pool.count)]
                    if held.contains(s) { held.remove(s) } else { held.insert(s) }
                    _ = d.handle(.observed(held, at: date))
                case 1, 2:
                    if let o = d.visibleOffer {
                        let answers: [MeetingDetector.Answer] = [.accepted, .dismissed, .never, .displaced, .refused]
                        _ = d.handle(.answered(offerId: o.id, answers[next(answers.count)], at: date))
                    }
                case 3:
                    switch next(5) {
                    case 0: env.pillHidden.toggle()
                    case 1: env.screenRecording.toggle()
                    case 2: env.meetingSince = env.meetingSince == nil ? date : nil
                    case 3:
                        let key = pool[next(pool.count)].key
                        if env.ignoredKeys.contains(key) { env.ignoredKeys.remove(key) } else { env.ignoredKeys.insert(key) }
                    default: env.offersEnabled.toggle()
                    }
                    _ = d.handle(.environment(env, at: date))
                case 4:                                     // the pointer moves onto / off the pill
                    hover.toggle()
                    _ = d.handle(.tick(at: date, pointerOnPill: hover))
                default:
                    _ = d.handle(.observed(held, at: date))
                }
                // The host: tick at every deadline that has come due.
                var guardCount = 0
                while let deadline = d.nextDeadline, deadline <= date {
                    _ = d.handle(.tick(at: date, pointerOnPill: hover))
                    guardCount += 1
                    if guardCount > 3 {
                        Issue.record("run \(run) step \(step): nextDeadline \(deadline.timeIntervalSince(t0)) stays due at now=\(now) (hover \(hover))")
                        return
                    }
                }
            }
        }
    }
}
