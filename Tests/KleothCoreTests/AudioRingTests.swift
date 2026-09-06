import Testing
import Foundation
@testable import KleothCore

/// The position-addressed audio ring (design §3.1, §4.2). Every case here is
/// something that actually happens during a recording: jittery timestamps, a
/// source that goes away, a buffer that arrives after its slot was mixed, a
/// 16 kHz mono Bluetooth mic feeding a stereo bus, and a session long enough to
/// lap the ring.
@Suite struct AudioRingTests {
    private let tolerance = ScreenRecordingDefaults.mixAlignToleranceFrames

    /// Interleaved stereo test signal where every sample of frame `i` is
    /// `value(i)` — so a read can be checked frame by frame.
    private func stereo(_ frames: Int, _ value: (Int) -> Float) -> [Float] {
        var out = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            out[i * 2] = value(i)
            out[i * 2 + 1] = value(i)
        }
        return out
    }

    private func write(_ ring: inout AudioRing, _ samples: [Float], channels: Int, at position: Int64, tolerance: Int) -> Int {
        samples.withUnsafeBufferPointer { ring.write($0, channels: channels, at: position, tolerance: tolerance) }
    }

    private func read(_ ring: inout AudioRing, frames: Int, at position: Int64) -> (samples: [Float], real: Int) {
        var out = [Float](repeating: .nan, count: frames * 2)
        let real = out.withUnsafeMutableBufferPointer { ring.read(into: $0, count: frames, at: position) }
        return (out, real)
    }

    @Test func aContiguousStreamLandsFrameForFrame() {
        var ring = AudioRing(capacityFrames: 4_800, channels: 2)
        #expect(write(&ring, stereo(100) { Float($0) + 1 }, channels: 2, at: 0, tolerance: tolerance) == 100)
        #expect(write(&ring, stereo(100) { Float($0) + 101 }, channels: 2, at: 100, tolerance: tolerance) == 100)
        #expect(ring.writeCursor == 200)

        let (samples, real) = read(&ring, frames: 200, at: 0)
        #expect(real == 200)
        #expect(samples[0] == 1)
        #expect(samples[199 * 2] == 200)
        #expect(ring.dropped == 0)
    }

    @Test func jitterInsideTheToleranceIsAppendedContiguously() {
        var ring = AudioRing(capacityFrames: 4_800, channels: 2)
        _ = write(&ring, stereo(100) { _ in 1 }, channels: 2, at: 0, tolerance: tolerance)
        // Stamped 8 frames late (0.17 ms) — well inside the 2 ms tolerance.
        _ = write(&ring, stereo(100) { _ in 2 }, channels: 2, at: 108, tolerance: tolerance)
        #expect(ring.writeCursor == 200)

        let (samples, real) = read(&ring, frames: 200, at: 0)
        #expect(real == 200)
        // No hole at 100..108 — the second buffer was snapped to the cursor.
        #expect(samples[100 * 2] == 2)
        #expect(samples[107 * 2] == 2)
    }

    @Test func jitterInsideTheToleranceTheOtherWayDoesNotOverlap() {
        var ring = AudioRing(capacityFrames: 4_800, channels: 2)
        _ = write(&ring, stereo(100) { _ in 1 }, channels: 2, at: 0, tolerance: tolerance)
        // Stamped 8 frames EARLY: honoring it literally would overwrite the
        // previous buffer's tail — a click.
        _ = write(&ring, stereo(100) { _ in 2 }, channels: 2, at: 92, tolerance: tolerance)
        #expect(ring.writeCursor == 200)

        let (samples, _) = read(&ring, frames: 200, at: 0)
        #expect(samples[99 * 2] == 1)
        #expect(samples[100 * 2] == 2)
    }

    @Test func aRealGapReadsBackAsSilence() {
        var ring = AudioRing(capacityFrames: 4_800, channels: 2)
        _ = write(&ring, stereo(100) { _ in 1 }, channels: 2, at: 0, tolerance: tolerance)
        // 100 frames past the cursor — far outside the tolerance, so it is
        // honored literally and the hole stays a hole.
        _ = write(&ring, stereo(100) { _ in 2 }, channels: 2, at: 200, tolerance: tolerance)
        #expect(ring.writeCursor == 300)

        let (samples, real) = read(&ring, frames: 300, at: 0)
        #expect(real == 300)
        #expect(samples[99 * 2] == 1)
        #expect(samples[150 * 2] == 0)
        #expect(samples[199 * 2] == 0)
        #expect(samples[200 * 2] == 2)
    }

    @Test func readingPastTheWriteCursorGivesZerosAndZeroRealFrames() {
        var ring = AudioRing(capacityFrames: 4_800, channels: 2)
        _ = write(&ring, stereo(100) { _ in 1 }, channels: 2, at: 0, tolerance: tolerance)

        let (tail, real) = read(&ring, frames: 100, at: 100)
        #expect(real == 0)
        #expect(tail.allSatisfy { $0 == 0 })

        // A read that straddles the cursor is partly real.
        var later = AudioRing(capacityFrames: 4_800, channels: 2)
        _ = write(&later, stereo(100) { _ in 1 }, channels: 2, at: 0, tolerance: tolerance)
        let (straddle, straddleReal) = read(&later, frames: 200, at: 0)
        #expect(straddleReal == 100)
        #expect(straddle[100 * 2] == 0)
    }

    @Test func aLateBufferIsDroppedAndCounted() {
        var ring = AudioRing(capacityFrames: 4_800, channels: 2)
        _ = write(&ring, stereo(960) { _ in 1 }, channels: 2, at: 0, tolerance: tolerance)
        _ = read(&ring, frames: 960, at: 0)          // the pump consumed 0..960
        #expect(ring.readCursor == 960)

        // Fully behind the read cursor: nothing stored, all counted.
        let stored = write(&ring, stereo(200) { _ in 9 }, channels: 2, at: 500, tolerance: tolerance)
        #expect(stored == 0)
        #expect(ring.dropped == 200)

        // Straddling it (and far enough back that the tolerance does not snap
        // it forward): the tail survives, the head is counted.
        let partial = write(&ring, stereo(200) { _ in 7 }, channels: 2, at: 800, tolerance: tolerance)
        #expect(partial == 40)
        #expect(ring.dropped == 360)
        let (samples, real) = read(&ring, frames: 40, at: 960)
        #expect(real == 40)
        #expect(samples[0] == 7)
    }

    @Test func writesWrapAroundAndOnlyTheLastCapacitySurvives() {
        var ring = AudioRing(capacityFrames: 1_000, channels: 2)
        for block in 0..<5 {
            _ = write(&ring, stereo(400) { _ in Float(block + 1) }, channels: 2, at: Int64(block * 400), tolerance: tolerance)
        }
        #expect(ring.writeCursor == 2_000)

        // The newest 1000 frames (1000..2000) are intact...
        let (fresh, freshReal) = read(&ring, frames: 200, at: 1_800)
        #expect(freshReal == 200)
        #expect(fresh[0] == 5)

        // ...and everything lapped is gone, reported as zero real frames.
        var second = AudioRing(capacityFrames: 1_000, channels: 2)
        for block in 0..<5 {
            _ = write(&second, stereo(400) { _ in Float(block + 1) }, channels: 2, at: Int64(block * 400), tolerance: tolerance)
        }
        let (stale, staleReal) = read(&second, frames: 200, at: 0)
        #expect(staleReal == 0)
        #expect(stale.allSatisfy { $0 == 0 })
    }

    @Test func aMonoSourceIsDuplicatedIntoBothChannels() {
        var ring = AudioRing(capacityFrames: 4_800, channels: 2)
        let mono: [Float] = (0..<100).map { Float($0) + 1 }
        #expect(write(&ring, mono, channels: 1, at: 0, tolerance: tolerance) == 100)
        #expect(ring.writeCursor == 100)

        let (samples, real) = read(&ring, frames: 100, at: 0)
        #expect(real == 100)
        for frame in 0..<100 {
            #expect(samples[frame * 2] == Float(frame + 1))
            #expect(samples[frame * 2 + 1] == Float(frame + 1))
        }
    }

    @Test func anEmptyOrMalformedWriteIsANoOp() {
        var ring = AudioRing(capacityFrames: 4_800, channels: 2)
        #expect(write(&ring, [], channels: 2, at: 0, tolerance: tolerance) == 0)
        #expect(write(&ring, [1, 2, 3, 4], channels: 0, at: 0, tolerance: tolerance) == 0)
        // One float at two channels is less than a whole frame.
        #expect(write(&ring, [1], channels: 2, at: 0, tolerance: tolerance) == 0)
        #expect(ring.writeCursor == 0)
    }

    @Test func aBufferLongerThanTheRingKeepsItsTail() {
        var ring = AudioRing(capacityFrames: 100, channels: 2)
        let stored = write(&ring, stereo(250) { Float($0) }, channels: 2, at: 0, tolerance: tolerance)
        #expect(stored == 100)
        #expect(ring.writeCursor == 250)

        let (samples, real) = read(&ring, frames: 100, at: 150)
        #expect(real == 100)
        #expect(samples[0] == 150)
        #expect(samples[99 * 2] == 249)
    }

    @Test func aSourceThatAttachesMidSessionLandsAtItsOwnPosition() {
        // The mic starting 3 s into a recording: nothing before it is invented.
        var ring = AudioRing(capacityFrames: 96_000, channels: 2)
        _ = write(&ring, stereo(960) { _ in 0.5 }, channels: 2, at: 144_000, tolerance: tolerance)
        #expect(ring.writeCursor == 144_960)

        let (early, earlyReal) = read(&ring, frames: 960, at: 0)
        #expect(earlyReal == 0)
        #expect(early.allSatisfy { $0 == 0 })

        let (late, lateReal) = read(&ring, frames: 960, at: 144_000)
        #expect(lateReal == 960)
        #expect(late[0] == 0.5)
    }
}
