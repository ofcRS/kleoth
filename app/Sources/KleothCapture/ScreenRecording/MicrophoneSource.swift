import AVFoundation
import Foundation
import KleothCore
import os

/// The microphone lane of a screen recording: a **third** `AVAudioEngine` input
/// tap whose per-buffer `AVAudioTime.hostTime` is forwarded, converted to
/// 48 kHz float and written into the mic ring at the position that timestamp
/// implies (design §4.1, §4.2).
///
/// Why an engine of its own rather than `SCStreamConfiguration.captureMicrophone`
/// (15.0): those buffers arrive with a different format description **on an
/// independent clock** that has to be offset by hand, and feeding both
/// ScreenCaptureKit audio types into one writer input corrupts the container —
/// which is the exact class of problem this design removes. It would also leave
/// the 14.4 floor on a second code path. `AVAudioTime.hostTime` is
/// `mach_absolute_time`, i.e. the same clock as the video PTS, on every OS
/// version.
///
/// Why a separate engine rather than a second tap on `MicCapture`'s: an
/// `AVAudioNode` bus allows exactly one tap, and a screen recording must be
/// able to start while a meeting and a dictation are already running. Two
/// concurrent engines on one device are proven on this project
/// (`DictationCapture.swift:55-60`); three is the extrapolation the manual
/// checklist verifies (§8 #11).
///
/// Format: converted to 48 kHz Float32 **interleaved** at `min(sourceChannels, 2)`
/// channels. A mono source stays mono here and is duplicated into both ring
/// channels by `AudioRing` — deliberately, because `AVAudioConverter`'s own
/// 1 → 2 channel mapping is not reliably a duplication, and a 16 kHz mono
/// Bluetooth HFP mic is the common case (72cca9a).
///
/// **Threading:** `start` / `stop` and the configuration-change handler are
/// main-thread; the tap callback runs on the render thread and copies its
/// converted block onto the audio queue before touching the ring. Every stored
/// property is main-thread-only except the preallocated converter scratch,
/// which only the render thread touches between `start` and `stop`.
/// `@unchecked Sendable` on that argument.
final class MicrophoneSource: @unchecked Sendable {
    private static let log = Logger(subsystem: "dev.kleoth", category: "ScreenRecording")
    /// The tap's requested buffer size — the same 2048 the dictation path uses.
    private static let tapBufferSize: AVAudioFrameCount = 2048

    private let engine = AVAudioEngine()
    private let audioQueue: DispatchQueue
    private let rings: AudioRingBox
    private let clock: HostClockMath
    private let sampleRate: Double
    private let onStarted: @Sendable () -> Void
    private let onLost: @Sendable (String) -> Void

    private var running = false
    private var tapFormat: AVAudioFormat?
    private var configurationObserver: (any NSObjectProtocol)?
    /// Constant shift applied to every mic timestamp, in host ticks: the input
    /// device's presentation latency plus the §4.5 clap-test knob. Negative
    /// ticks move the audio earlier.
    private var offsetTicks: Int64 = 0

    init(
        audioQueue: DispatchQueue,
        rings: AudioRingBox,
        clock: HostClockMath,
        sampleRate: Double,
        onStarted: @escaping @Sendable () -> Void,
        onLost: @escaping @Sendable (String) -> Void
    ) {
        self.audioQueue = audioQueue
        self.rings = rings
        self.clock = clock
        self.sampleRate = sampleRate
        self.onStarted = onStarted
        self.onLost = onLost
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    /// Opens the input and starts feeding the mic ring.
    ///
    /// - Throws: `DictationCaptureError.noInputDevice` when the node vends no
    ///   usable format, `.engineFailed` when the engine will not start. A
    ///   caller that wants a mic-less recording simply does not call this.
    func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        // The HARDWARE format (`inputFormat`) — `outputFormat` goes stale when
        // the default input device changes under an idle engine, and a tap at
        // the stale format raises (see `DictationCapture.start()`).
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw DictationCaptureError.noInputDevice
        }

        let latency = input.presentationLatency + ScreenRecordingDefaults.micOffsetCompensation
        offsetTicks = clock.hostTicks(forSeconds: latency)

        guard let converter = makeConverter(from: format) else {
            throw DictationCaptureError.noInputDevice
        }
        do {
            try install(converter, format: format)
        } catch {
            throw DictationCaptureError.engineFailed(error)
        }
        tapFormat = format

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw DictationCaptureError.engineFailed(error)
        }
        running = true
        observeConfigurationChanges()
        onStarted()
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        removeConfigurationObserver()
    }

    // MARK: - Conversion

    /// A converter from the node's native format to interleaved Float32 at the
    /// mix rate, with a scratch buffer sized once, up front — the render thread
    /// allocates nothing.
    private final class Converter: @unchecked Sendable {
        let converter: AVAudioConverter
        let scratch: AVAudioPCMBuffer
        let channels: Int
        let ratio: Double

        init?(from source: AVAudioFormat, sampleRate: Double, bufferSize: AVAudioFrameCount) {
            let channelCount = min(Int(source.channelCount), Int(ScreenRecordingDefaults.audioChannels))
            guard channelCount > 0,
                  let target = AVAudioFormat(
                      commonFormat: .pcmFormatFloat32,
                      sampleRate: sampleRate,
                      channels: AVAudioChannelCount(channelCount),
                      interleaved: true
                  ),
                  let converter = AVAudioConverter(from: source, to: target)
            else { return nil }
            let ratio = sampleRate / max(source.sampleRate, 1)
            let capacity = AVAudioFrameCount((Double(bufferSize) * 4 * ratio).rounded(.up)) + 1024
            guard let scratch = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
            self.converter = converter
            self.scratch = scratch
            self.channels = channelCount
            self.ratio = ratio
        }
    }

    /// Hands one tap buffer to `convert` exactly once — the `TapWriter`
    /// idiom (`AudioFormat.swift:216-226`).
    private final class ConsumableBuffer: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }

    private func makeConverter(from format: AVAudioFormat) -> Converter? {
        Converter(from: format, sampleRate: sampleRate, bufferSize: Self.tapBufferSize)
    }

    /// - Throws: ``ObjCExceptionError`` when AVFoundation raises on a format
    ///   that does not match the hardware (see `DictationCapture.installTap`).
    private func install(_ converter: Converter, format: AVAudioFormat) throws {
        let rings = rings
        let clock = clock
        let sampleRate = sampleRate
        let audioQueue = audioQueue
        let offsetTicks = offsetTicks
        let input = engine.inputNode

        try catchingObjCExceptions {
          input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: format) { buffer, when in
            // The tap buffer is only valid inside this callback, so the
            // converted block is copied into a small array that is handed to
            // the audio queue. One allocation per ~43 ms; the dictation path
            // runs the whole AAC encoder on this thread today.
            let source = ConsumableBuffer(buffer)
            var error: NSError?
            converter.scratch.frameLength = 0
            let status = converter.converter.convert(to: converter.scratch, error: &error) { _, outStatus in
                guard let next = source.take() else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                return next
            }
            guard status != .error, error == nil else { return }
            let frames = Int(converter.scratch.frameLength)
            guard frames > 0, let channelData = converter.scratch.floatChannelData else { return }

            let samples = frames * converter.channels
            let block = [Float](UnsafeBufferPointer(start: channelData[0], count: samples))

            // `AVAudioTime.hostTime` stamps the FIRST frame of the *input*
            // buffer; the converted block starts at the same instant.
            let raw = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
            let shifted = shift(raw, by: -offsetTicks)

            audioQueue.async {
                guard let origin = rings.origin else { return }
                let position = clock.samplePosition(hostTime: shifted, origin: origin, sampleRate: sampleRate)
                block.withUnsafeBufferPointer {
                    rings.writeMic($0, channels: converter.channels, at: position)
                }
            }
          }
        }
    }

    // MARK: - Device changes

    private func observeConfigurationChanges() {
        guard configurationObserver == nil else { return }
        let box = OwnerBox(self)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { _ in
            box.owner?.handleConfigurationChange()
        }
    }

    /// The input device (or its format) changed under a live recording:
    /// reinstall the tap at the node's new format and restart the engine, the
    /// `DictationCapture.handleConfigurationChange` shape
    /// (`DictationCapture.swift:399-422`). The recording keeps going either
    /// way — a mic that cannot be reopened just leaves a zero-filled stretch
    /// the summary reports as a `MicGap` — so this never tears the session
    /// down, it only reports.
    private func handleConfigurationChange() {
        guard running else { return }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)   // the hardware format — see `start()`
        if engine.isRunning, let current = tapFormat, TapWriter.matches(format, current) {
            return   // the usual Bluetooth profile settle: nothing to do
        }
        input.removeTap(onBus: 0)
        engine.stop()
        guard format.channelCount > 0, format.sampleRate > 0, let converter = makeConverter(from: format) else {
            giveUp("the microphone went away")
            return
        }
        // The new device has its own latency — built-in is a few ms, a
        // Bluetooth HFP headset can be over a hundred — so the timestamp shift
        // is recomputed rather than carried over from the old one.
        offsetTicks = clock.hostTicks(forSeconds: input.presentationLatency + ScreenRecordingDefaults.micOffsetCompensation)
        do {
            try install(converter, format: format)
        } catch {
            giveUp(error.localizedDescription)
            return
        }
        tapFormat = format
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            giveUp(error.localizedDescription)
        }
    }

    private func giveUp(_ reason: String) {
        running = false
        removeConfigurationObserver()
        Self.log.error("screen recording microphone lost: \(reason, privacy: .public)")
        onLost(reason)
    }

    private func removeConfigurationObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    /// Carries a weak reference across the `@Sendable` notification block, the
    /// way `DictationCapture` does.
    private final class OwnerBox: @unchecked Sendable {
        weak var owner: MicrophoneSource?
        init(_ owner: MicrophoneSource) { self.owner = owner }
    }
}

/// Shifts a host timestamp by signed ticks without wrapping past zero.
private func shift(_ hostTime: UInt64, by ticks: Int64) -> UInt64 {
    if ticks >= 0 { return hostTime &+ UInt64(ticks) }
    let magnitude = UInt64(-ticks)
    return hostTime > magnitude ? hostTime - magnitude : 0
}
