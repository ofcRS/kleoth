import Testing
import Foundation
@testable import KleothCore

/// Pre-flight I-3 regression guard: a past `nextDeadline` would be a hot
/// loop in the host (which ticks at every deadline that has come due).
@Suite struct MeetingDetectorDeadlineTests {
    /// The host ticks at `nextDeadline`; after a `.tick(at: now)` the machine
    /// must never ask for a tick at or before `now` (a past deadline = a hot loop).
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
        for run in 0..<200 {
            var d = MeetingDetector()
            var now: TimeInterval = 0
            var held = Set<MeetingSource>()
            var env = MeetingDetector.Environment(offersEnabled: true)
            _ = d.handle(.environment(env, at: t0))
            for _ in 0..<400 {
                now += Double(next(4) + 1) * 0.5
                switch next(10) {
                case 0, 1, 2:
                    let s = pool[next(pool.count)]
                    if held.contains(s) { held.remove(s) } else { held.insert(s) }
                    _ = d.handle(.observed(held, at: t0.addingTimeInterval(now)))
                case 3:
                    if let o = d.visibleOffer {
                        let answers: [MeetingDetector.Answer] = [.accepted, .dismissed, .never, .displaced, .refused]
                        _ = d.handle(.answered(offerId: o.id, answers[next(answers.count)], at: t0.addingTimeInterval(now)))
                    }
                case 4:
                    switch next(4) {
                    case 0: env.pillHidden.toggle()
                    case 1: env.screenRecording.toggle()
                    case 2: env.meetingSince = env.meetingSince == nil ? t0.addingTimeInterval(now) : nil
                    default: env.offersEnabled.toggle()
                    }
                    _ = d.handle(.environment(env, at: t0.addingTimeInterval(now)))
                default:
                    _ = d.handle(.observed(held, at: t0.addingTimeInterval(now)))
                }
                // The host: tick at every deadline that has come due.
                var guardCount = 0
                while let deadline = d.nextDeadline, deadline <= t0.addingTimeInterval(now) {
                    _ = d.handle(.tick(at: t0.addingTimeInterval(now), pointerOnPill: false))
                    guardCount += 1
                    if guardCount > 3 {
                        Issue.record("run \(run): nextDeadline \(deadline.timeIntervalSince(t0)) stays due at now=\(now)")
                        return
                    }
                }
            }
        }
    }
}
