import Accelerate
import Foundation

/// The one DSP step of the screen-recording mixer: sum two lanes and limit the
/// result (design §3.1, §4.3).
///
/// It is the streamed form of `ChannelAudio.mixToMono`'s peak guard
/// (`ChannelAudio.swift:96-104`): that path can normalize offline because it
/// knows the whole file's peak first, and a real-time mixer never does. A hard
/// clip at ±0.97 is what stops the microphone — which has been measured on this
/// project at 6.1× full scale before normalization (CLAUDE.md 2026-07-22) — from
/// turning every loud syllable into a click once system audio is summed on top.
/// Per-source gain stays 1.0; AGC is deliberately deferred (§9).
public enum MixMath {
    /// The limiter's ceiling — the same 0.97 `ChannelAudio` normalizes to.
    public static let limit: Float = 0.97

    /// `out = clip(a + b, ±limit)` over `out.count` samples.
    ///
    /// A short (or empty) input lane is treated as **silence** for the samples
    /// it does not cover rather than truncating the block: either source can
    /// stop mid-block, and the output track must stay continuous.
    public static func sumAndLimit(
        _ a: UnsafeBufferPointer<Float>,
        _ b: UnsafeBufferPointer<Float>,
        into out: UnsafeMutableBufferPointer<Float>
    ) {
        guard let output = out.baseAddress, out.count > 0 else { return }
        let n = out.count
        let countA = min(a.count, n)
        let countB = min(b.count, n)

        if countA == n, countB == n, let left = a.baseAddress, let right = b.baseAddress {
            vDSP_vadd(left, 1, right, 1, output, 1, vDSP_Length(n))
        } else {
            output.update(repeating: 0, count: n)
            if countA > 0, let left = a.baseAddress {
                vDSP_vadd(left, 1, output, 1, output, 1, vDSP_Length(countA))
            }
            if countB > 0, let right = b.baseAddress {
                vDSP_vadd(right, 1, output, 1, output, 1, vDSP_Length(countB))
            }
        }

        var low = -limit
        var high = limit
        vDSP_vclip(output, 1, &low, &high, output, 1, vDSP_Length(n))
    }
}
