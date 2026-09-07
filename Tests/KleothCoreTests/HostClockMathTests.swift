import Testing
import Foundation
@testable import KleothCore

/// Host-clock arithmetic with the timebase injected (design §3.1, §4.2).
/// 125/3 is what Apple Silicon reports (a 24 MHz tick); 1/1 is Intel's
/// nanosecond tick. Everything downstream — where a mic buffer lands in its
/// ring, which sample position the pump is at — is this multiplication, so it
/// is worth pinning both.
@Suite struct HostClockMathTests {
    private let appleSilicon = HostClockMath(timebaseNumer: 125, timebaseDenom: 3)
    private let nanoseconds = HostClockMath(timebaseNumer: 1, timebaseDenom: 1)

    @Test func appleSiliconTicksAre24MHz() {
        #expect(abs(appleSilicon.seconds(fromHostTime: 24_000_000) - 1.0) < 1e-9)
        #expect(abs(appleSilicon.seconds(fromHostTime: 12_000_000) - 0.5) < 1e-9)
        #expect(abs(appleSilicon.secondsPerTick - 1.0 / 24_000_000) < 1e-15)
    }

    @Test func nanosecondTimebaseIsIdentityOverABillion() {
        #expect(abs(nanoseconds.seconds(fromHostTime: 1_000_000_000) - 1.0) < 1e-9)
        #expect(abs(nanoseconds.seconds(fromHostTime: 250_000_000) - 0.25) < 1e-9)
    }

    @Test func zeroAndOneAreNotSpecialCased() {
        #expect(appleSilicon.seconds(fromHostTime: 0) == 0)
        #expect(nanoseconds.seconds(fromHostTime: 0) == 0)
    }

    @Test func elapsedSecondsAreSignedAndNeverWrapAroundUInt64() {
        let origin: UInt64 = 1_000_000_000_000
        #expect(abs(appleSilicon.seconds(fromHostTime: origin, to: origin + 24_000_000) - 1.0) < 1e-6)
        // The reversed order is the one that would wrap to ~584 years if it
        // were computed as a plain UInt64 subtraction.
        let backwards = appleSilicon.seconds(fromHostTime: origin + 24_000_000, to: origin)
        #expect(abs(backwards + 1.0) < 1e-6)
    }

    @Test func samplePositionCountsFramesSinceTheOrigin() {
        let origin: UInt64 = 5_000_000_000
        let oneSecondLater = origin + 24_000_000
        #expect(appleSilicon.samplePosition(hostTime: oneSecondLater, origin: origin, sampleRate: 48_000) == 48_000)
        // 20 ms — one mix block.
        let block = origin + 480_000
        #expect(appleSilicon.samplePosition(hostTime: block, origin: origin, sampleRate: 48_000) == 960)
    }

    @Test func samplePositionOnTheNanosecondTimebase() {
        let origin: UInt64 = 7
        #expect(nanoseconds.samplePosition(hostTime: origin + 1_000_000_000, origin: origin, sampleRate: 48_000) == 48_000)
    }

    @Test func aTimestampBeforeTheOriginClampsToZero() {
        let origin: UInt64 = 24_000_000
        #expect(appleSilicon.samplePosition(hostTime: 0, origin: origin, sampleRate: 48_000) == 0)
        #expect(appleSilicon.samplePosition(hostTime: origin, origin: origin, sampleRate: 48_000) == 0)
        #expect(appleSilicon.samplePosition(hostTime: origin - 1, origin: origin, sampleRate: 48_000) == 0)
    }

    @Test func aNonPositiveSampleRateCannotProduceANonsensePosition() {
        let origin: UInt64 = 0
        #expect(appleSilicon.samplePosition(hostTime: 24_000_000, origin: origin, sampleRate: 0) == 0)
        #expect(appleSilicon.samplePosition(hostTime: 24_000_000, origin: origin, sampleRate: -48_000) == 0)
    }

    @Test func hostTicksRoundTripThroughSeconds() {
        let ticks = appleSilicon.hostTicks(forSeconds: 0.25)
        #expect(ticks == 6_000_000)
        #expect(appleSilicon.hostTicks(forSeconds: -0.25) == -6_000_000)
        #expect(appleSilicon.hostTicks(forSeconds: .nan) == 0)
    }

    @Test func aZeroTimebaseIsTreatedAsOneOverOne() {
        let degenerate = HostClockMath(timebaseNumer: 0, timebaseDenom: 0)
        #expect(degenerate.timebaseNumer == 1)
        #expect(degenerate.timebaseDenom == 1)
        #expect(abs(degenerate.seconds(fromHostTime: 1_000_000_000) - 1.0) < 1e-9)
    }

    @Test func precisionSurvivesADayOfUptime() {
        // ~24 h of 24 MHz ticks: the position must still be exact to the frame.
        let origin: UInt64 = 24_000_000 * 86_400
        let position = appleSilicon.samplePosition(
            hostTime: origin + 24_000_000 * 600, origin: origin, sampleRate: 48_000
        )
        #expect(position == 48_000 * 600)
    }
}
