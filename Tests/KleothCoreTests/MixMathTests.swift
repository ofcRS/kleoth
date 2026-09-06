import Testing
import Foundation
@testable import KleothCore

/// The mixer's single DSP step (design §3.1, §4.3): sum the mic and system
/// lanes, hard-limit at ±0.97. The mismatched-length cases are not theoretical —
/// either lane can stop mid-block, and the output track has to stay continuous.
@Suite struct MixMathTests {
    private func mix(_ a: [Float], _ b: [Float], count: Int) -> [Float] {
        var out = [Float](repeating: .nan, count: count)
        a.withUnsafeBufferPointer { left in
            b.withUnsafeBufferPointer { right in
                out.withUnsafeMutableBufferPointer { destination in
                    MixMath.sumAndLimit(left, right, into: destination)
                }
            }
        }
        return out
    }

    @Test func equalLengthLanesAreSummed() {
        let out = mix([0.1, -0.2, 0.3, 0], [0.2, 0.1, -0.3, 0], count: 4)
        #expect(abs(out[0] - 0.3) < 1e-6)
        #expect(abs(out[1] + 0.1) < 1e-6)
        #expect(abs(out[2]) < 1e-6)
        #expect(out[3] == 0)
    }

    @Test func theSumIsClippedAtPlusMinusPointNineSeven() {
        let out = mix([0.9, -0.9, 0.5], [0.9, -0.9, 0.4], count: 3)
        #expect(out[0] == MixMath.limit)
        #expect(out[1] == -MixMath.limit)
        #expect(abs(out[2] - 0.9) < 1e-6)
    }

    @Test func aSingleLaneAlreadyOverFullScaleIsLimitedToo() {
        // The measured 6.1× mic peak (CLAUDE.md 2026-07-22) must not reach the
        // encoder as a click even with nothing to sum it with.
        let out = mix([6.1, -6.1], [0, 0], count: 2)
        #expect(out[0] == MixMath.limit)
        #expect(out[1] == -MixMath.limit)
    }

    @Test func aShortLaneIsTreatedAsSilenceNotAsATruncation() {
        // The mic stops halfway through the block: the system lane must still
        // fill the whole block.
        let out = mix([0.5, 0.5], [0.25, 0.25, 0.25, 0.25], count: 4)
        #expect(abs(out[0] - 0.75) < 1e-6)
        #expect(abs(out[1] - 0.75) < 1e-6)
        #expect(abs(out[2] - 0.25) < 1e-6)
        #expect(abs(out[3] - 0.25) < 1e-6)
    }

    @Test func anEmptyLaneLeavesTheOtherIntact() {
        let out = mix([], [0.4, -0.4, 0.4], count: 3)
        #expect(abs(out[0] - 0.4) < 1e-6)
        #expect(abs(out[1] + 0.4) < 1e-6)
        #expect(abs(out[2] - 0.4) < 1e-6)
    }

    @Test func twoEmptyLanesProduceSilenceNotGarbage() {
        let out = mix([], [], count: 4)
        #expect(out.allSatisfy { $0 == 0 })
    }

    @Test func lanesLongerThanTheOutputAreCutToTheBlock() {
        let out = mix([1, 1, 1, 1, 1, 1], [0, 0, 0, 0, 0, 0], count: 2)
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0 == MixMath.limit })
    }

    @Test func aZeroLengthOutputIsANoOp() {
        var empty = [Float]()
        [Float(1)].withUnsafeBufferPointer { left in
            [Float(1)].withUnsafeBufferPointer { right in
                empty.withUnsafeMutableBufferPointer { destination in
                    MixMath.sumAndLimit(left, right, into: destination)
                }
            }
        }
        #expect(empty.isEmpty)
    }

    @Test func afullBlockOfTheRealSizeIsHandled() {
        // 960 frames × 2 channels — one 20 ms mix block.
        let samples = ScreenRecordingDefaults.mixBlockFrames * 2
        let out = mix(
            [Float](repeating: 0.6, count: samples),
            [Float](repeating: 0.6, count: samples),
            count: samples
        )
        #expect(out.count == samples)
        #expect(out.allSatisfy { $0 == MixMath.limit })
    }
}
