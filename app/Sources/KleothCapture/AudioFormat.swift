import Foundation
import AVFoundation
import AudioToolbox

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
    /// The bit rate is clamped to what the AAC encoder accepts for this sample
    /// rate and channel count (``maxAACBitRate``): a Bluetooth headset mic
    /// runs at 16 kHz mono, where the encoder caps out at 48 kbps and rejects
    /// our 64/128 kbps defaults outright (`AVAudioFile` init fails with
    /// `kAudioFormatUnsupportedDataFormatError`, '!dat'), which is how the
    /// first external microphone broke both dictation and meeting recording.
    ///
    /// - Parameters:
    ///   - sampleRate: Output sample rate in Hz.
    ///   - channels: Number of channels (1 = mono, 2 = stereo / multi-channel).
    ///   - bitRate: Requested encoder bit rate in bits/second (clamped).
    /// - Returns: A settings dictionary keyed by the `AVFoundation` setting keys.
    public static func aacSettings(
        sampleRate: Double = defaultSampleRate,
        channels: Int = 1,
        bitRate: Int = defaultBitRate
    ) -> [String: Any] {
        var rate = bitRate
        if let cap = maxAACBitRate(sampleRate: sampleRate, channels: channels) {
            rate = min(rate, cap)
        }
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: rate,
        ]
    }

    /// The highest bit rate the system AAC encoder accepts for a PCM source of
    /// this sample rate and channel count, from the converter's
    /// `kAudioConverterApplicableEncodeBitRates`, or `nil` when the query
    /// itself fails (then the caller's request is passed through unchanged).
    /// Measured 2026-09-06: 8 kHz mono → 24 kbps, 16 kHz mono → 48, 24 kHz
    /// mono → 64, 32 kHz mono → 96, 48 kHz mono → 256, 48 kHz stereo → 320.
    public static func maxAACBitRate(sampleRate: Double, channels: Int) -> Int? {
        guard let source = pcmFloat32(sampleRate: sampleRate, channels: channels) else { return nil }
        var sourceDescription = source.streamDescription.pointee
        var destination = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(max(1, channels)),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var converter: AudioConverterRef?
        guard AudioConverterNew(&sourceDescription, &destination, &converter) == noErr, let converter else {
            return nil
        }
        defer { AudioConverterDispose(converter) }
        var size: UInt32 = 0
        guard AudioConverterGetPropertyInfo(converter, kAudioConverterApplicableEncodeBitRates, &size, nil) == noErr,
              size >= UInt32(MemoryLayout<AudioValueRange>.size) else { return nil }
        var ranges = [AudioValueRange](
            repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size
        )
        guard AudioConverterGetProperty(converter, kAudioConverterApplicableEncodeBitRates, &size, &ranges) == noErr else {
            return nil
        }
        guard let top = ranges.map(\.mMaximum).max(), top.isFinite, top > 0 else { return nil }
        return Int(top)
    }

    /// Opens an AAC file for writing with ``aacSettings``. If the encoder
    /// still refuses the (clamped) bit rate — an input format the range query
    /// did not anticipate — it retries once with no bit rate at all, letting
    /// the encoder pick its own, so a capture never fails on bit rate alone.
    public static func openAACFile(
        at url: URL, sampleRate: Double, channels: Int, bitRate: Int = defaultBitRate
    ) throws -> AVAudioFile {
        var settings = aacSettings(sampleRate: sampleRate, channels: channels, bitRate: bitRate)
        do {
            return try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            settings.removeValue(forKey: AVEncoderBitRateKey)
            return try AVAudioFile(forWriting: url, settings: settings)
        }
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

/// Writes an input tap's buffers into a preopened AAC file, converting on the
/// fly when the device's stream format differs from the file's processing
/// format (sample rate and/or channel count).
///
/// Why: the file is opened once, at the format the input node reported at
/// `start`. A Bluetooth headset switches profiles the moment its mic is opened
/// (A2DP → HFP) and any device can be swapped mid-session; both post
/// `AVAudioEngineConfigurationChange`, after which the tap must be reinstalled
/// at the node's *new* format — which the file cannot accept directly. Routing
/// every write through this converter keeps the file valid across the switch,
/// so a session survives instead of being cut at the moment of the change.
///
/// Real-time budget: one `AVAudioConverter.convert` (pure PCM → PCM, no
/// encoding) into a scratch buffer allocated up front, then the file write —
/// which already runs the AAC encoder on this thread today. No allocation, no
/// locking. `@unchecked Sendable` for the same reason as ``SendableAudioFileBox``:
/// only the single render/IO thread touches it between start and stop.
final class TapWriter: @unchecked Sendable {
    let file: AVAudioFile
    /// The format buffers arrive in (the tap's format).
    let sourceFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let scratch: AVAudioPCMBuffer?

    /// - Parameters:
    ///   - file: the open destination; its `processingFormat` is the target.
    ///   - sourceFormat: the tap's format.
    ///   - bufferSize: the tap's requested buffer size, used to size the
    ///     scratch buffer (with headroom — Core Audio may deliver more).
    /// - Returns: `nil` when a converter is needed but cannot be built.
    init?(file: AVAudioFile, sourceFormat: AVAudioFormat, bufferSize: AVAudioFrameCount) {
        self.file = file
        self.sourceFormat = sourceFormat
        let target = file.processingFormat
        if Self.matches(sourceFormat, target) {
            converter = nil
            scratch = nil
            return
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: target) else { return nil }
        let ratio = target.sampleRate / max(sourceFormat.sampleRate, 1)
        let capacity = AVAudioFrameCount((Double(bufferSize) * 4 * ratio).rounded(.up)) + 1024
        guard let scratch = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        self.converter = converter
        self.scratch = scratch
    }

    /// Sample rate, channel count and sample layout agree — the file accepts
    /// the buffer as is.
    static func matches(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate
            && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat
            && a.isInterleaved == b.isInterleaved
    }

    private final class ConsumableBuffer: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }

    /// Writes one tap buffer. Returns the number of frames appended to the
    /// file **at the file's sample rate**, so callers can derive a duration
    /// that stays right across a format change.
    func write(_ buffer: AVAudioPCMBuffer) throws -> AVAudioFrameCount {
        guard let converter, let scratch else {
            try file.write(from: buffer)
            return buffer.frameLength
        }
        // The pull block is drained synchronously inside `convert`, on this
        // thread; the holder hands the buffer over exactly once. Allocating the
        // tiny holder per callback is the one heap op here — the AAC encoder
        // in `file.write` already allocates far more.
        let source = ConsumableBuffer(buffer)
        var conversionError: NSError?
        scratch.frameLength = 0
        let status = converter.convert(to: scratch, error: &conversionError) { _, outStatus in
            guard let next = source.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return next
        }
        if let conversionError { throw conversionError }
        guard status != .error else { throw ChannelAudio.AudioError.formatUnavailable }
        guard scratch.frameLength > 0 else { return 0 }
        try file.write(from: scratch)
        return scratch.frameLength
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
