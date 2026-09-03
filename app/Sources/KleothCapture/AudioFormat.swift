import Foundation
import AVFoundation

/// Helpers for producing AAC encoder settings used when writing `.m4a` files,
/// and for constructing matching `AVAudioFormat` values.
///
/// All helpers are pure and free of shared mutable state, so they are safe to
/// call from any context under Swift 6 strict concurrency.
public enum AudioFormat {
    /// Default capture sample rate (Hz). 48 kHz matches the typical macOS
    /// hardware/aggregate-device clock, but call sites should prefer the
    /// device's actual rate when one is available.
    public static let defaultSampleRate: Double = 48_000

    /// Default AAC encoder bit rate (bits/second) per output file.
    public static let defaultBitRate: Int = 128_000

    /// AAC (`.m4a`) encoder settings suitable for `AVAudioFile(forWriting:settings:)`.
    ///
    /// - Parameters:
    ///   - sampleRate: Output sample rate in Hz.
    ///   - channels: Number of channels (1 = mono, 2 = stereo / multi-channel).
    ///   - bitRate: Encoder bit rate in bits/second.
    /// - Returns: A settings dictionary keyed by the `AVFoundation` setting keys.
    public static func aacSettings(
        sampleRate: Double = defaultSampleRate,
        channels: Int = 1,
        bitRate: Int = defaultBitRate
    ) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate,
        ]
    }

    /// A standard 32-bit float, non-interleaved PCM format for processing
    /// (the format `AVAudioEngine` and Core Audio taps prefer to vend).
    ///
    /// - Parameters:
    ///   - sampleRate: Sample rate in Hz.
    ///   - channels: Channel count (clamped to at least 1).
    /// - Returns: An `AVAudioFormat`, or `nil` if the parameters are invalid.
    public static func pcmFloat32(
        sampleRate: Double = defaultSampleRate,
        channels: Int = 1
    ) -> AVAudioFormat? {
        let channelCount = AVAudioChannelCount(max(1, channels))
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        )
    }
}

/// A lock-free, single-word `Bool` flag that can be safely *flipped* from a
/// real-time audio callback and read from a control thread afterward.
///
/// Backed by a heap word so the value survives being captured into a
/// `@Sendable` callback without boxing on the audio thread. It is marked
/// `@unchecked Sendable` because the only writer is the (single) render/IO
/// thread, which sets it at most once, and the reader observes it only after
/// the audio engine/device has been stopped — a point that establishes a
/// happens-before relationship. No locks or allocations occur in the callback.
final class RenderFlag: @unchecked Sendable {
    private let pointer = UnsafeMutablePointer<Bool>.allocate(capacity: 1)

    init() {
        pointer.initialize(to: false)
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    /// Resets the flag to `false`. Call from the control thread before start.
    func reset() {
        pointer.pointee = false
    }

    /// Sets the flag to `true`. Real-time safe (single non-blocking store).
    func raise() {
        pointer.pointee = true
    }

    /// The current value. Read after the audio thread has been quiesced.
    var isRaised: Bool {
        pointer.pointee
    }
}

/// Wraps a non-`Sendable` `AVAudioFile` so it can be captured into a `@Sendable`
/// real-time callback.
///
/// `@unchecked Sendable` is sound here because the wrapped file is only ever
/// touched by a single audio render/IO thread between `start` and `stop`, and is
/// released only after that thread has been quiesced.
final class SendableAudioFileBox: @unchecked Sendable {
    let file: AVAudioFile

    init(_ file: AVAudioFile) {
        self.file = file
    }
}

/// A lock-free, single-word `Float` slot holding the most recent RMS level
/// measured on the audio render thread.
///
/// The heap word lets a `@Sendable` real-time callback store into it without
/// boxing or allocating, as with ``RenderFlag`` — but the *safety argument is
/// different*. `RenderFlag`/`RenderCounter` are read only after `engine.stop()`
/// (a real happens-before edge). This slot is read at 20 Hz by the `@MainActor`
/// level poll **while the render thread is storing into it**: there is no
/// synchronization edge, so this is a deliberate, benign data race, not a
/// synchronized read. It is tolerated because a naturally-aligned 32-bit
/// store does not tear on arm64/x86_64 and a stale or momentarily odd meter
/// value is inconsequential — but a ThreadSanitizer build WILL report it.
/// The proper fix is a relaxed atomic (`Atomic<UInt32>` + `bitPattern`, macOS
/// 15+, or a stdatomic shim) once the package floor allows it.
final class RenderLevel: @unchecked Sendable {
    private let pointer = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    init() {
        pointer.initialize(to: 0)
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    /// Resets the level to zero. Call from the control thread before start.
    func reset() {
        pointer.pointee = 0
    }

    /// Stores the latest RMS. Real-time safe (single non-blocking store).
    func store(_ rms: Float) {
        pointer.pointee = rms
    }

    /// The most recently stored RMS.
    var value: Float {
        pointer.pointee
    }
}

/// A lock-free, single-word `UInt64` accumulator for frames written from the
/// audio render thread.
///
/// `@unchecked Sendable` for the same reason as ``RenderFlag``: the render/IO
/// thread is the sole writer, and the control thread reads the total only after
/// the engine has been stopped — which establishes a happens-before edge.
final class RenderCounter: @unchecked Sendable {
    private let pointer = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)

    init() {
        pointer.initialize(to: 0)
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    /// Resets the counter to zero. Call from the control thread before start.
    func reset() {
        pointer.pointee = 0
    }

    /// Adds `n` to the running total. Real-time safe (single non-blocking
    /// read-modify-write from the one writer thread).
    func add(_ n: UInt64) {
        pointer.pointee &+= n
    }

    /// The accumulated total. Read after the audio thread has been quiesced.
    var value: UInt64 {
        pointer.pointee
    }
}
