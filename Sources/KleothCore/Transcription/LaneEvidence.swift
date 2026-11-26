import Accelerate
import Foundation

/// One meeting lane's level per envelope hop, in dB, with the two levels
/// ``ChannelAttribution`` measures it against: its own noise floor and the
/// level above which it carries a voice.
///
/// Both come from the lane itself, never from the other lane: a 16 kHz headset
/// mic and 48 kHz system audio sit tens of dB apart, so raw loudness says
/// nothing about who spoke.
struct LaneLevels {
    /// The level of a hop past the lane's end, or of digital silence.
    static let silence: Float = -140
    /// A lane whose loudest second stays this close to its floor carries no
    /// voice at all (a dead or muted mic): it counts as no lane. Low enough
    /// that a quiet user 8 dB over a noisy mic's floor still counts.
    static let minimumVoiceRangeDB: Float = 6
    /// The voice band is this wide or wider on a normal lane; a narrower one
    /// (a quiet voice on a noisy mic) gets a lower voice threshold and a faint band.
    static let fullVoiceRangeDB: Float = 24

    /// Per-hop RMS level in dB (≥ ``silence``); empty for a missing or dead lane.
    let db: [Float]
    /// The lane's noise floor: its 10th percentile, never below -100 dB (a lane
    /// that is digital silence most of the time still has a usable floor).
    let floor: Float
    /// The lane's own loud level: what its loudest second reaches. A user who
    /// speaks for a few seconds of a long meeting still sets it.
    let loud: Float
    /// A hop at or above this carries a voice: halfway from the floor to the
    /// loud level, kept within 6–12 dB over the floor; or 25 dB under the
    /// lane's 95th percentile when that is higher, so a remote line with an
    /// open, noisy mic does not count as talking all the time.
    let voiced: Float
    /// The bottom of a narrow voice band (3 dB over the floor), where a quiet
    /// voice's softer syllables sit; `voiced` on a lane with a full band.
    let faint: Float

    init(energy: [Float], hopSeconds: Double) {
        let levels = energy.map { 20 * log10f(max($0, 1e-7)) }
        let sorted = levels.sorted()
        func percentile(_ p: Double) -> Float {
            sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
        }
        let topSecond = max(1, Int((1 / max(hopSeconds, 1e-3)).rounded()))
        guard !sorted.isEmpty,
              sorted[max(0, sorted.count - topSecond)] - max(percentile(0.10), -100) >= Self.minimumVoiceRangeDB else {
            db = []
            floor = Self.silence
            loud = Self.silence
            voiced = .infinity
            faint = .infinity
            return
        }
        db = levels
        floor = max(percentile(0.10), -100)
        loud = sorted[max(0, sorted.count - topSecond)]
        let range = loud - floor
        voiced = max(floor + min(12, max(6, range / 2)), percentile(0.95) - 25)
        faint = range < Self.fullVoiceRangeDB ? min(voiced, floor + 3) : voiced
    }

    /// No lane: missing, unreadable, header-only, or never more than a few dB
    /// over its own floor.
    var isEmpty: Bool { db.isEmpty }
    var count: Int { db.count }

    subscript(_ hop: Int) -> Float {
        hop >= 0 && hop < db.count ? db[hop] : Self.silence
    }
}

/// How much of one lane's sound reaches the other: laptop speakers into the
/// mic (bleed), or, less often, the user's own voice played back into the
/// system lane (a call app monitoring the mic, a loopback device).
///
/// The two lanes are separate captures on separate clocks, so they drift apart
/// over a long meeting (seconds over two hours). The leak is therefore found per
/// window of ``windowSeconds``: the lag that best lines the lanes' levels up
/// (searched over ±``maxLagSeconds``), and the leak's gain at that lag. Bleed is
/// predicted from the other lane at that lag, a fraction of a second either
/// side, rather than over a wide fixed window, which would also swallow the
/// user's real replies right after the remote stops.
struct LeakModel {
    enum Direction: Equatable {
        /// The mic hears the system lane: `mic[i + lag] ≈ system[i] + gain`.
        case systemIntoMic
        /// The system lane hears the mic: `system[i] ≈ mic[i + lag] + gain`.
        case micIntoSystem
    }

    struct Leak: Equatable {
        var lag: Int
        var gain: Float
    }

    static let windowSeconds = 120.0
    static let stepSeconds = 60.0
    static let maxLagSeconds = 10.0
    /// The lag's slack either side (reverberation, the lag moving within a window).
    static let slackSeconds = 0.15
    /// A window's lanes line up at all only above this correlation.
    static let minimumCorrelation: Float = 0.3
    /// The share of the source lane's voiced hops that must show on the other
    /// lane for a leak to exist at all.
    static let minimumCarried = 0.6
    /// Voiced seconds a window needs on the source lane to decide anything.
    static let minimumVoicedSeconds = 5.0
    /// Voiced seconds the source lane needs, over every window that lines up,
    /// for a leak to exist at all: a short exchange can line up by chance.
    static let minimumLeakSeconds = 20.0

    let direction: Direction?
    /// Per hop: the leak in force there (nil: none).
    private let leakAtHop: [Leak?]
    private let slack: Int

    /// Seconds of the meeting with a leak in force.
    let seconds: Double

    /// How many hops the mic lane runs behind the system lane at `hop`
    /// (`mic[i + lag]` is `system[i]`'s moment), where a leak is modelled; 0
    /// elsewhere. A check of "the other lane at the same moment" reads it shifted.
    func lag(at hop: Int) -> Int {
        guard hop >= 0, hop < leakAtHop.count, let leak = leakAtHop[hop] else { return 0 }
        return leak.lag
    }

    /// Whether a leak is modelled at `hop`.
    func isModelled(at hop: Int) -> Bool {
        hop >= 0 && hop < leakAtHop.count && leakAtHop[hop] != nil
    }

    /// The level the leak puts on the mic at `hop` (``LaneLevels/silence`` when
    /// the mic hears nothing of the system lane there).
    func micLeak(at hop: Int, system: LaneLevels) -> Float {
        guard direction == .systemIntoMic, hop < leakAtHop.count, let leak = leakAtHop[hop] else {
            return LaneLevels.silence
        }
        return leak.gain + Self.maxLevel(system, around: hop - leak.lag, slack: slack)
    }

    /// The level the leak puts on the system lane at `hop`.
    func systemLeak(at hop: Int, mic: LaneLevels) -> Float {
        guard direction == .micIntoSystem, hop < leakAtHop.count, let leak = leakAtHop[hop] else {
            return LaneLevels.silence
        }
        return leak.gain + Self.maxLevel(mic, around: hop + leak.lag, slack: slack)
    }

    private static func maxLevel(_ lane: LaneLevels, around center: Int, slack: Int) -> Float {
        var level = LaneLevels.silence
        for hop in (center - slack)...(center + slack) { level = max(level, lane[hop]) }
        return level
    }

    /// No leak anywhere (one lane missing, or nothing to line up).
    static let none = LeakModel(direction: nil, leakAtHop: [], slack: 0, seconds: 0)

    private init(direction: Direction?, leakAtHop: [Leak?], slack: Int, seconds: Double) {
        self.direction = direction
        self.leakAtHop = leakAtHop
        self.slack = slack
        self.seconds = seconds
    }

    /// Finds the leak, if any, between the two lanes.
    static func estimate(mic: LaneLevels, system: LaneLevels, hopSeconds: Double) -> LeakModel {
        guard !mic.isEmpty, !system.isEmpty, hopSeconds > 0 else { return .none }
        let count = max(mic.count, system.count)
        let length = max(1, Int((windowSeconds / hopSeconds).rounded()))
        let step = max(1, Int((stepSeconds / hopSeconds).rounded()))
        let maxLag = max(1, Int((maxLagSeconds / hopSeconds).rounded()))
        let minimumVoiced = max(1, Int((minimumVoicedSeconds / hopSeconds).rounded()))

        // The series to line up: each lane's level above its own floor, clipped,
        // minus its ±0.5 s moving average. A leak copies the syllables; two
        // different turns that happen to line up at some shift share only their
        // on/off shape, which the moving average takes out.
        let half = max(1, Int((0.5 / hopSeconds).rounded()))
        func fineStructure(_ lane: LaneLevels) -> [Float] {
            let level = (0..<count).map { Double(min(40, max(0, lane[$0] - lane.floor))) }
            var sums = [Double](repeating: 0, count: count + 1)
            for i in 0..<count { sums[i + 1] = sums[i] + level[i] }
            return (0..<count).map { i in
                let lower = max(0, i - half), upper = min(count, i + half + 1)
                return Float(level[i] - (sums[upper] - sums[lower]) / Double(upper - lower))
            }
        }
        let xs = fineStructure(system)
        // The mic series, padded by `maxLag` zeros either side so every shift is in range.
        let xm = [Float](repeating: 0, count: maxLag) + fineStructure(mic) + [Float](repeating: 0, count: maxLag)
        var prefix = [Double](repeating: 0, count: xm.count + 1)
        var prefixSquares = [Double](repeating: 0, count: xm.count + 1)
        for (i, value) in xm.enumerated() {
            prefix[i + 1] = prefix[i] + Double(value)
            prefixSquares[i + 1] = prefixSquares[i] + Double(value) * Double(value)
        }

        // 1. Each window's best lag and its correlation.
        var starts: [Int] = []
        var start = 0
        repeat {
            starts.append(start)
            start += step
        } while start + length / 2 < count
        // Among near-equal peaks (turns that repeat at a steady pace line up at
        // several shifts), the lag nearest the previous window's: lanes drift
        // slowly.
        var lags: [(lag: Int, correlation: Float)?] = []
        var reference = 0
        for w0 in starts {
            let w1 = min(count, w0 + length)
            let n = w1 - w0
            guard n > 1 else { lags.append(nil); continue }
            var sumX = 0.0, sumXX = 0.0
            for i in w0..<w1 {
                sumX += Double(xs[i])
                sumXX += Double(xs[i]) * Double(xs[i])
            }
            let varX = sumXX - sumX * sumX / Double(n)
            guard varX > 1e-6 else { lags.append(nil); continue }
            var correlations = [Float](repeating: -.infinity, count: 2 * maxLag + 1)
            xs.withUnsafeBufferPointer { x in
                xm.withUnsafeBufferPointer { m in
                    for lag in -maxLag...maxLag {
                        let y0 = w0 + lag + maxLag
                        let sumY = prefix[y0 + n] - prefix[y0]
                        let sumYY = prefixSquares[y0 + n] - prefixSquares[y0]
                        let varY = sumYY - sumY * sumY / Double(n)
                        guard varY > 1e-6 else { continue }
                        var dot: Float = 0
                        vDSP_dotpr(x.baseAddress! + w0, 1, m.baseAddress! + y0, 1, &dot, vDSP_Length(n))
                        let covariance = Double(dot) - sumX * sumY / Double(n)
                        correlations[lag + maxLag] = Float(covariance / (varX * varY).squareRoot())
                    }
                }
            }
            guard let peak = correlations.max(), peak > -.infinity else { lags.append(nil); continue }
            let lag = (-maxLag...maxLag)
                .filter { correlations[$0 + maxLag] >= peak - 0.05 }
                .min { abs($0 - reference) < abs($1 - reference) }!
            lags.append((lag, correlations[lag + maxLag]))
            if correlations[lag + maxLag] >= minimumCorrelation { reference = lag }
        }

        // 2. The direction, once for the meeting: which lane's voice reliably
        //    shows up on the other (all of the remote reaches a mic by the
        //    speakers; only the user's share of the mic shows on the system lane).
        var systemVoiced = 0, micUpThen = 0, micVoiced = 0, systemUpThen = 0
        var systemToMic: [Float] = [], micToSystem: [Float] = []
        for (index, w0) in starts.enumerated() {
            guard let best = lags[index], best.correlation >= minimumCorrelation else { continue }
            for i in w0..<min(count, w0 + length) {
                let s = system[i], m = mic[i + best.lag]
                if s >= system.voiced {
                    systemVoiced += 1
                    if m >= mic.floor + 8 { micUpThen += 1; systemToMic.append(m - s) }
                }
                if m >= mic.voiced {
                    micVoiced += 1
                    if s >= system.floor + 8 { systemUpThen += 1; micToSystem.append(s - m) }
                }
            }
        }
        let minimumLeak = max(1, Int((minimumLeakSeconds / hopSeconds).rounded()))
        let carriedToMic = systemVoiced >= minimumLeak ? Double(micUpThen) / Double(systemVoiced) : 0
        let carriedToSystem = micVoiced >= minimumLeak ? Double(systemUpThen) / Double(micVoiced) : 0
        let direction: Direction
        switch (carriedToMic >= minimumCarried, carriedToSystem >= minimumCarried) {
        case (false, false):
            return .none
        case (true, false):
            direction = .systemIntoMic
        case (false, true):
            direction = .micIntoSystem
        case (true, true):
            // Both look carried (one side did nearly all the talking). Prefer the
            // clearer share, then the steadier gain; physical bleed on a tie.
            if abs(carriedToMic - carriedToSystem) >= 0.1 {
                direction = carriedToMic > carriedToSystem ? .systemIntoMic : .micIntoSystem
            } else {
                direction = spread(micToSystem) + 3 < spread(systemToMic) ? .micIntoSystem : .systemIntoMic
            }
        }

        // 3. Per window: the leak's gain at its lag (the upper quartile of the
        //    source-to-target level difference, so most of the leak is covered),
        //    no leak where the lanes don't line up, undecided with too little voice.
        enum Decision { case undecided, none, leak(Leak) }
        var decisions: [Decision] = []
        for (index, w0) in starts.enumerated() {
            let w1 = min(count, w0 + length)
            let lag = lags[index]?.lag ?? 0
            var differences: [Float] = []
            var sourceVoiced = 0
            for i in w0..<w1 {
                let s = system[i], m = mic[i + lag]
                switch direction {
                case .systemIntoMic:
                    guard s >= system.voiced else { continue }
                    sourceVoiced += 1
                    if m >= mic.floor + 8 { differences.append(m - s) }
                case .micIntoSystem:
                    guard m >= mic.voiced else { continue }
                    sourceVoiced += 1
                    if s >= system.floor + 8 { differences.append(s - m) }
                }
            }
            guard sourceVoiced >= minimumVoiced else { decisions.append(.undecided); continue }
            guard let best = lags[index], best.correlation >= minimumCorrelation,
                  differences.count >= minimumVoiced else {
                decisions.append(.none)
                continue
            }
            decisions.append(.leak(Leak(lag: lag, gain: percentile(differences, 0.75))))
        }
        // An undecided window takes its nearest decided neighbour's leak.
        func resolved(_ index: Int) -> Leak? {
            for distance in 0..<decisions.count {
                for candidate in [index - distance, index + distance] where decisions.indices.contains(candidate) {
                    switch decisions[candidate] {
                    case .undecided: continue
                    case .none: return nil
                    case .leak(let leak): return leak
                    }
                }
            }
            return nil
        }
        let windowLeaks = decisions.indices.map(resolved)

        // 4. Each hop takes the window centred nearest to it.
        var leakAtHop = [Leak?](repeating: nil, count: count)
        var covered = 0
        for hop in 0..<count {
            let nearest = min(starts.count - 1, max(0, Int(((Double(hop) - Double(length) / 2) / Double(step)).rounded())))
            leakAtHop[hop] = windowLeaks[nearest]
            if windowLeaks[nearest] != nil { covered += 1 }
        }
        let slack = max(1, Int((slackSeconds / hopSeconds).rounded()))
        return LeakModel(direction: direction, leakAtHop: leakAtHop, slack: slack, seconds: Double(covered) * hopSeconds)
    }

    private static func percentile(_ values: [Float], _ p: Double) -> Float {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    /// The interquartile range, or infinity with too few values to tell.
    private static func spread(_ values: [Float]) -> Float {
        guard values.count >= 4 else { return .infinity }
        return percentile(values, 0.75) - percentile(values, 0.25)
    }
}
