import Foundation

/// mach host time ↔ seconds ↔ sample positions, with the timebase **injected**
/// so the arithmetic is testable off a real Mac (design §3.1, §4.2).
///
/// Why this exists at all: a screen recording has three timestamp sources —
/// ScreenCaptureKit's video PTS, ScreenCaptureKit's audio PTS and
/// `AVAudioTime.hostTime` from the microphone tap — and all three are the SAME
/// clock (`mach_absolute_time`; `SCStream.synchronizationClock` is
/// `CMClock.hostTimeClock`). Turning each of them into an absolute sample
/// position relative to one origin is the only conversion the mixer needs, and
/// it is pure arithmetic, so it lives here rather than in the capture target.
///
/// The timebase is a rational: `seconds = ticks × numer / denom / 1e9`. Apple
/// Silicon reports 125/3 (a 24 MHz tick); Intel reports 1/1 (a nanosecond
/// tick). Both are covered by tests.
public struct HostClockMath: Sendable, Equatable {
    public let timebaseNumer: UInt32
    public let timebaseDenom: UInt32

    /// - Parameters:
    ///   - timebaseNumer: `mach_timebase_info_data_t.numer` (0 is treated as 1).
    ///   - timebaseDenom: `mach_timebase_info_data_t.denom` (0 is treated as 1).
    public init(timebaseNumer: UInt32, timebaseDenom: UInt32) {
        self.timebaseNumer = max(1, timebaseNumer)
        self.timebaseDenom = max(1, timebaseDenom)
    }

    /// The running machine's timebase. The only impure entry point, and the one
    /// the recorder uses; every test constructs the injected form instead.
    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        self.init(timebaseNumer: info.numer, timebaseDenom: info.denom)
    }

    /// Seconds per host tick — 1/24 000 000 on Apple Silicon.
    public var secondsPerTick: Double {
        Double(timebaseNumer) / Double(timebaseDenom) / 1_000_000_000
    }

    /// Absolute host time in seconds since boot.
    public func seconds(fromHostTime t: UInt64) -> Double {
        Double(t) * secondsPerTick
    }

    /// Signed elapsed seconds from `a` to `b`, computed without ever
    /// subtracting two `UInt64`s in the wrong order (which would wrap to a
    /// ~584-year interval and silently poison every position derived from it).
    public func seconds(fromHostTime a: UInt64, to b: UInt64) -> Double {
        let delta = b >= a ? Double(b - a) : -Double(a - b)
        return delta * secondsPerTick
    }

    /// Host ticks for a duration in seconds; negative durations stay negative
    /// so callers can shift a timestamp backwards (the mic's latency
    /// compensation, §4.5).
    public func hostTicks(forSeconds seconds: Double) -> Int64 {
        guard seconds.isFinite else { return 0 }
        return Int64((seconds / secondsPerTick).rounded())
    }

    /// Absolute sample position of a host timestamp, relative to `origin` (the
    /// host time of the writer's session start = the first appended video
    /// frame).
    ///
    /// Clamped at 0: audio stamped before the session origin has nowhere to go
    /// in a ring addressed from zero, and the pump never reads a negative
    /// position. Callers that must distinguish "before the origin" from
    /// "exactly at it" compare `seconds(fromHostTime:to:)` themselves.
    public func samplePosition(hostTime t: UInt64, origin: UInt64, sampleRate: Double) -> Int64 {
        guard sampleRate > 0 else { return 0 }
        let elapsed = seconds(fromHostTime: origin, to: t)
        guard elapsed > 0 else { return 0 }
        let position = (elapsed * sampleRate).rounded()
        guard position.isFinite, position < Double(Int64.max) else { return 0 }
        return Int64(position)
    }
}
