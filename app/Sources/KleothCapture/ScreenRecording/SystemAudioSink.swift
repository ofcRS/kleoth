import AVFoundation
import CoreMedia
import Foundation
import KleothCore

/// The ScreenCaptureKit `.audio` output: turns each `CMSampleBuffer` of system
/// audio into an absolute-position write into the system `AudioRing`
/// (design §4.2).
///
/// Why the system lane comes from `SCStream` and not from a second
/// `SystemAudioTap`: video and audio out of one `SCStream` share the host clock
/// (`SCStream.synchronizationClock`), so **video ↔ system audio need no
/// alignment at all** — the single largest source of drift in a screen recorder
/// is designed away rather than corrected. `SystemAudioTap` would additionally
/// have to start forwarding `inInputTime` (it discards it,
/// `SystemAudioTap.swift:227`) and two concurrent Core Audio process taps are
/// unprobed. §4.1 records the decision in full.
///
/// ScreenCaptureKit vends **planar (non-interleaved) Float32**; the ring is
/// interleaved, so a scratch buffer does the interleave in place. It is sized
/// once for the largest block seen so far and reused.
///
/// **Threading:** the stream output is registered on the session's audio queue,
/// so `handle` and every stored property below are audio-queue only.
/// `@unchecked Sendable` on that single-queue argument.
final class SystemAudioSink: @unchecked Sendable {
    private let rings: AudioRingBox
    private let clock: HostClockMath
    private let sampleRate: Double
    private var scratch: [Float] = []
    /// Meter for the pill: the RMS of the most recent block, stored on the
    /// audio queue and read from the main actor without a hop. See
    /// ``LevelWord`` for the (deliberate, benign) race that buys.
    let level = LevelWord()

    init(rings: AudioRingBox, clock: HostClockMath, sampleRate: Double) {
        self.rings = rings
        self.clock = clock
        self.sampleRate = sampleRate
    }

    /// Audio-queue only.
    func handle(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.isNumeric else { return }
        // Nothing to be in sync with until the writer's session has an origin
        // (the first video frame), so the ring write waits for one — but the
        // METER does not need a timeline, and is taken for every block that
        // arrives, so the pill's system bar is live from the first one, the
        // way the mic lane's is.
        let position = rings.origin.map {
            clock.samplePosition(hostTime: CMClockConvertHostTimeToSystemUnits(pts), origin: $0, sampleRate: sampleRate)
        }

        try? sampleBuffer.withAudioBufferList { list, _ in
            let buffers = Array(list)
            guard let first = buffers.first, first.mDataByteSize > 0 else { return }

            if buffers.count == 1 {
                // Already interleaved (or genuinely mono).
                let channels = max(1, Int(first.mNumberChannels))
                guard let data = first.mData else { return }
                let samples = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                let pointer = data.assumingMemoryBound(to: Float.self)
                level.storeRMS(of: pointer, count: samples)
                guard let position else { return }
                rings.writeSystem(
                    UnsafeBufferPointer(start: pointer, count: samples),
                    channels: channels,
                    at: position
                )
                return
            }

            // Planar: one buffer per channel, all the same length.
            let channels = min(buffers.count, Int(ScreenRecordingDefaults.audioChannels))
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            guard frames > 0 else { return }
            let needed = frames * channels
            if scratch.count < needed { scratch = [Float](repeating: 0, count: needed) }

            scratch.withUnsafeMutableBufferPointer { destination in
                guard let out = destination.baseAddress else { return }
                for channel in 0..<channels {
                    guard let data = buffers[channel].mData else { continue }
                    let source = data.assumingMemoryBound(to: Float.self)
                    let available = min(frames, Int(buffers[channel].mDataByteSize) / MemoryLayout<Float>.size)
                    for frame in 0..<available {
                        out[frame * channels + channel] = source[frame]
                    }
                }
            }
            scratch.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                level.storeRMS(of: base, count: needed)
                guard let position else { return }
                rings.writeSystem(
                    UnsafeBufferPointer(start: base, count: needed),
                    channels: channels,
                    at: position
                )
            }
        }
    }
}
