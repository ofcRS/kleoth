import Foundation
import AVFoundation
import Accelerate
import KleothCore

/// Errors thrown by ``Recorder``.
public enum RecorderError: Error, Sendable {
    case notStopped
    case missingSourceFile(URL)
    case formatUnavailable
    case bufferAllocationFailed
}

/// Owns the microphone and system-audio capture, writing `mic.m4a` and
/// `system.m4a` as separate files, and can build a single 2-channel `.m4a`
/// (channel 0 = mic, channel 1 = system) suitable for Scribe multi-channel
/// transcription.
///
/// A shared start anchor (`mach_absolute_time()`) is captured at ``start`` so
/// downstream code can align the two source streams if needed.
///
/// Requires macOS 14.4+ (it owns a `SystemAudioTap`). Live recording also
/// requires a signed app bundle plus microphone and audio-capture TCC grants;
/// this type compiles without them but ``start(outputDir:)`` fails at runtime
/// when a permission is denied.
@available(macOS 14.4, *)
public final class Recorder {
    private let mic: MicCapture
    private let systemTap: SystemAudioTap

    private var outputDirectory: URL?
    private var isRecording = false

    /// Absolute-time anchor captured at the moment recording started, for later
    /// alignment of the mic and system streams. `nil` until ``start`` is called.
    public private(set) var startAnchor: UInt64?

    /// Live meters for the pill's meeting bar: the RMS (0…1) of the most
    /// recent mic tap buffer and system IO buffer. Raw, like
    /// `ScreenRecorder.levels` — the pill shapes them. `.zero` when stopped
    /// (both words reset on stop), read at ~20 Hz by `MeetingPillBridge`.
    public var levels: AudioLevels {
        guard isRecording else { return .zero }
        return AudioLevels(mic: mic.level.level, system: systemTap.level.level)
    }

    /// Canonical file names within the output directory.
    public static let micFileName = "mic.m4a"
    public static let systemFileName = "system.m4a"
    public static let combinedFileName = "combined.m4a"

    public init() {
        self.mic = MicCapture()
        self.systemTap = SystemAudioTap()
    }

    /// The microphone to open — a CoreAudio device UID — or nil for the
    /// system input. Read at `start(outputDir:)`; the same app-wide pick the
    /// dictation and screen-recording captures honour.
    public var inputDeviceId: String?

    /// URL of the mic recording within the active/last output directory.
    public var micFileURL: URL? {
        outputDirectory?.appendingPathComponent(Self.micFileName)
    }

    /// URL of the system-audio recording within the active/last output directory.
    public var systemFileURL: URL? {
        outputDirectory?.appendingPathComponent(Self.systemFileName)
    }

    /// Begins recording mic and system audio into `outputDir` as two separate
    /// files (`mic.m4a`, `system.m4a`). Idempotent while already recording.
    ///
    /// - Note: requires signed bundle + TCC grants at runtime.
    public func start(outputDir: URL) throws {
        guard !isRecording else { return }

        try FileManager.default.createDirectory(
            at: outputDir,
            withIntermediateDirectories: true
        )
        outputDirectory = outputDir

        let micURL = outputDir.appendingPathComponent(Self.micFileName)
        let systemURL = outputDir.appendingPathComponent(Self.systemFileName)

        // Capture the alignment anchor immediately before kicking off IO.
        startAnchor = mach_absolute_time()

        do {
            try systemTap.start(writingTo: systemURL)
        } catch {
            startAnchor = nil
            outputDirectory = nil
            throw error
        }

        do {
            mic.inputDeviceId = inputDeviceId
            try mic.start(writingTo: micURL)
        } catch {
            // Roll back the system tap so we don't leak a running device.
            systemTap.stop()
            startAnchor = nil
            outputDirectory = nil
            throw error
        }

        isRecording = true
    }

    /// Spec-named alias for ``start(outputDir:)``.
    ///
    /// - Note: requires signed bundle + TCC grants at runtime.
    public func start(intoDirectory directory: URL) throws {
        try start(outputDir: directory)
    }

    /// Whether the microphone lane failed to write a buffer during the last
    /// session, so `mic.m4a` is short or empty. Valid after ``stop()``.
    public var micWriteFailed: Bool { mic.didEncounterWriteFailure }

    /// Stops recording and finalizes both output files. Idempotent.
    public func stop() throws {
        guard isRecording else { return }
        // Stop the mic engine first, then the system device; both teardown
        // paths are themselves idempotent and quiesce their audio threads
        // before closing files.
        mic.stop()
        systemTap.stop()
        isRecording = false
    }

    /// Combines `mic.m4a` and `system.m4a` into a single 2-channel `.m4a`
    /// (channel 0 = mic, channel 1 = system) for multi-channel transcription.
    ///
    /// Must be called *after* ``stop()``. Both source files are read as mono
    /// float32, resampled to one common rate, interleaved into a 2-channel
    /// file (zero-padded to the longer source), and re-encoded as AAC — see
    /// ``combine(channel0:channel1:outputURL:)``.
    @discardableResult
    public func buildTwoChannelFile(outputURL: URL) throws -> URL {
        guard !isRecording else { throw RecorderError.notStopped }

        guard let dir = outputDirectory else {
            throw RecorderError.missingSourceFile(outputURL)
        }
        let micURL = dir.appendingPathComponent(Self.micFileName)
        let systemURL = dir.appendingPathComponent(Self.systemFileName)

        return try Self.combine(
            channel0: micURL,
            channel1: systemURL,
            outputURL: outputURL
        )
    }

    /// Builds the 2-channel `.m4a` (channel 0 = mic, channel 1 = system) from the
    /// two per-channel files **without a live `Recorder`**, so the heavy decode +
    /// AAC re-encode can be hopped off the main actor.
    ///
    /// `buildTwoChannelFile()` does the same work but is an instance method that
    /// reads `outputDirectory`; this static form takes only `Sendable` URLs, so a
    /// caller on the main actor can run it inside `Task.detached` and `await` the
    /// result. For a long recording the combine is seconds of CPU-bound work that
    /// would otherwise freeze the UI when run synchronously on stop. At least one
    /// source must exist.
    @discardableResult
    public static func combineChannels(micURL: URL, systemURL: URL, outputURL: URL) throws -> URL {
        try combine(channel0: micURL, channel1: systemURL, outputURL: outputURL)
    }

    /// Whether the file at `url` opens and holds at least one frame. A capture
    /// whose every write failed leaves a header-only file that exists and
    /// decodes to nothing.
    public static func holdsAudio(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length > 0
    }

    /// Spec-named convenience: builds the 2-channel upload file at
    /// `combined.m4a` inside the output directory and returns it.
    @discardableResult
    public func twoChannelFile() throws -> URL {
        guard let dir = outputDirectory else { throw RecorderError.notStopped }
        return try buildTwoChannelFile(
            outputURL: dir.appendingPathComponent(Self.combinedFileName)
        )
    }

    /// Spec alias for ``twoChannelFile()`` — the single file to upload to Scribe.
    @discardableResult
    public func mixedDownFile() throws -> URL {
        try twoChannelFile()
    }

    // MARK: - Channel combine

    /// Writes a single 2-channel AAC file with `channel0` (the microphone) on
    /// the left and `channel1` (the other side) on the right, both on ONE
    /// timebase. At least one source must hold audio.
    ///
    /// The two lanes are captured at their own rates — `system.m4a` at the
    /// process tap's 48 kHz, `mic.m4a` at the microphone's (16 kHz for a
    /// Bluetooth headset in HFP, 44.1 kHz for a MacBook's array). This used to
    /// copy both lanes frame for frame at the MICROPHONE's rate: with a 16 kHz
    /// headset the other side played three times too slow and the file lasted
    /// three times the meeting (2026-11-18). Each lane is now resampled to a
    /// common rate before the two are interleaved.
    ///
    /// The common rate is the HIGHER of the two: resampling the system lane
    /// down to a headset's 16 kHz would cut everything above 8 kHz from the
    /// other side's voices (and any music or screen share); taking the
    /// microphone up to 48 kHz loses nothing and costs only file size. At
    /// 48 kHz stereo the AAC encoder takes up to 320 kbps, so the default
    /// 128 kbps passes `AudioFormat.aacSettings`' clamp unchanged.
    ///
    /// Streamed: each lane is read twice in chunks (once for its loudness,
    /// once to convert), so memory stays a few chunks whatever the meeting's
    /// length. The loudness balance is the one `ChannelAudio.normalizeLoudness`
    /// applies — one gain per lane from its whole-file RMS, then a ±0.97
    /// ceiling — so in-app playback isn't lopsided when the mic is much
    /// quieter than the other side.
    static func combine(channel0: URL, channel1: URL, outputURL: URL) throws -> URL {
        let file0 = openLane(channel0)
        let file1 = openLane(channel1)
        guard file0 != nil || file1 != nil else {
            throw RecorderError.missingSourceFile(channel0)
        }

        let sampleRate = max(
            file0?.processingFormat.sampleRate ?? 0,
            file1?.processingFormat.sampleRate ?? 0
        )
        guard sampleRate > 0,
              let stereoFormat = AudioFormat.pcmFloat32(sampleRate: sampleRate, channels: 2),
              let monoFormat = AudioFormat.pcmFloat32(sampleRate: sampleRate, channels: 1) else {
            throw RecorderError.formatUnavailable
        }
        let lane0 = try file0.map { try MonoLaneReader(file: $0, outputFormat: monoFormat) }
        let lane1 = try file1.map { try MonoLaneReader(file: $0, outputFormat: monoFormat) }

        let outFile = try AudioFormat.openAACFile(at: outputURL, sampleRate: sampleRate, channels: 2)

        // Write in capped chunks so we never allocate an unbounded buffer.
        let chunk: AVAudioFrameCount = 16384
        guard let block0 = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: chunk),
              let block1 = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: chunk),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: chunk),
              let out = outBuffer.floatChannelData else {
            throw RecorderError.bufferAllocationFailed
        }
        while true {
            let count0 = try lane0?.read(into: block0) ?? 0
            let count1 = try lane1?.read(into: block1) ?? 0
            let count = max(count0, count1)
            // A lane reads short only at its end: both done, the file is too.
            guard count > 0 else { break }
            outBuffer.frameLength = count
            // Silence first so the region past the shorter lane's end stays quiet.
            memset(out[0], 0, Int(count) * MemoryLayout<Float>.size)
            memset(out[1], 0, Int(count) * MemoryLayout<Float>.size)
            if count0 > 0, let src = block0.floatChannelData { out[0].update(from: src[0], count: Int(count0)) }
            if count1 > 0, let src = block1.floatChannelData { out[1].update(from: src[0], count: Int(count1)) }
            try outFile.write(from: outBuffer)
        }

        return outputURL
    }

    /// The lane file opened for reading, or `nil` if it does not exist or
    /// holds no audio.
    ///
    /// A file that cannot even be OPENED counts as holding none: a capture
    /// whose every write failed leaves a 28-byte header (`mic.m4a`,
    /// 2026-11-16), and treating that as an error threw away the combine — so
    /// the other, intact channel never became `meeting.m4a` and the meeting
    /// could not be played or transcribed.
    private static func openLane(_ url: URL) -> AVAudioFile? {
        guard FileManager.default.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url),
              file.length > 0 else { return nil }
        return file
    }
}

/// One capture lane read back as loudness-balanced mono Float32 at the
/// combine's rate, a chunk at a time (``Recorder/combine(channel0:channel1:outputURL:)``).
///
/// Mono comes first, at the file's own rate: the channels are AVERAGED here
/// (as ``MonoDownmix`` does on the capture side) rather than handed to
/// `AVAudioConverter`, which turns some discrete layouts into silence with a
/// success status. Only a mono → mono rate change is left to the converter.
///
/// `@unchecked Sendable`: the converter's input block is typed `@Sendable`
/// and pulls from this reader, but it runs synchronously inside `convert`,
/// on the one thread that owns the reader.
final class MonoLaneReader: @unchecked Sendable {
    private let file: AVAudioFile
    private let sourceFormat: AVAudioFormat
    /// Mono at the file's rate: what the converter (or the caller) is fed.
    private let sourceMono: AVAudioFormat
    /// nil when the file already runs at the output rate.
    private let converter: AVAudioConverter?
    /// The loudness gain for the whole lane, or nil to leave it as it is.
    private let gain: Float?
    /// The file read buffer, in the file's own channel layout.
    private let readBuffer: AVAudioPCMBuffer
    private var sourceExhausted = false
    private var finished = false
    /// A read error inside the converter's pull block, rethrown by ``read(into:)``.
    private var pullError: Error?

    private static let readChunk: AVAudioFrameCount = 16384

    /// Measures the lane's loudness in one streamed pass, then rewinds.
    init(file: AVAudioFile, outputFormat: AVAudioFormat) throws {
        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatFloat32, format.channelCount > 0,
              let sourceMono = AudioFormat.pcmFloat32(sampleRate: format.sampleRate, channels: 1),
              let readBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.readChunk) else {
            throw RecorderError.formatUnavailable
        }
        self.file = file
        self.sourceFormat = format
        self.sourceMono = sourceMono
        self.readBuffer = readBuffer
        if format.sampleRate == outputFormat.sampleRate {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: sourceMono, to: outputFormat) else {
                throw RecorderError.formatUnavailable
            }
            self.converter = converter
        }

        // Pass 1: the whole lane's mean square, chunk by chunk (Double: an
        // hours-long lane is billions of samples).
        file.framePosition = 0
        var sumOfSquares = 0.0
        var frames = 0
        while let block = try Self.readMono(file, into: readBuffer, as: sourceMono, upTo: Self.readChunk) {
            var chunkSum: Float = 0
            vDSP_svesq(block.floatChannelData![0], 1, &chunkSum, vDSP_Length(block.frameLength))
            sumOfSquares += Double(chunkSum)
            frames += Int(block.frameLength)
        }
        let rms = frames > 0 ? Float((sumOfSquares / Double(frames)).squareRoot()) : 0
        gain = ChannelAudio.loudnessGain(rms: rms)
        file.framePosition = 0
    }

    /// Fills `buffer` (mono, at the output rate) with up to its capacity and
    /// returns the frames written: fewer only at the end of the lane, 0 past it.
    func read(into buffer: AVAudioPCMBuffer) throws -> AVAudioFrameCount {
        buffer.frameLength = 0
        guard !finished else { return 0 }
        guard let converter else {
            var filled: AVAudioFrameCount = 0
            while filled < buffer.frameCapacity, let block = try nextBlock(upTo: buffer.frameCapacity - filled) {
                buffer.floatChannelData![0].advanced(by: Int(filled))
                    .update(from: block.floatChannelData![0], count: Int(block.frameLength))
                filled += block.frameLength
            }
            if filled < buffer.frameCapacity { finished = true }
            buffer.frameLength = filled
            return filled
        }
        // Pull-based conversion: a rate change alters the frame count, and the
        // one-shot `convert(to:from:)` refuses it. The converter asks for input
        // as it needs it, and drains its tail once told the stream ended.
        var conversionError: NSError?
        let status = converter.convert(to: buffer, error: &conversionError) { packets, outStatus in
            do {
                guard let block = try self.nextBlock(upTo: max(1, min(packets, Self.readChunk))) else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return block
            } catch {
                self.pullError = error
                outStatus.pointee = .endOfStream
                return nil
            }
        }
        if let pullError { throw pullError }
        if let conversionError { throw conversionError }
        switch status {
        case .error: throw RecorderError.formatUnavailable
        case .endOfStream: finished = true
        default: break
        }
        return buffer.frameLength
    }

    /// The next block of the lane at its own rate, mono, with the lane's gain
    /// and ceiling applied, in a buffer of its own (the converter may hold on
    /// to it); nil at the end of the file.
    private func nextBlock(upTo frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        guard !sourceExhausted else { return nil }
        guard let block = try Self.readMono(file, into: readBuffer, as: sourceMono, upTo: min(frames, Self.readChunk)) else {
            sourceExhausted = true
            return nil
        }
        if let gain {
            ChannelAudio.apply(gain: gain, to: block.floatChannelData![0], count: Int(block.frameLength))
        }
        return block
    }

    /// Reads up to `frames` from `file` and averages its channels into a new
    /// mono buffer; nil once the file has no more.
    private static func readMono(
        _ file: AVAudioFile, into readBuffer: AVAudioPCMBuffer, as mono: AVAudioFormat, upTo frames: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer? {
        guard file.framePosition < file.length else { return nil }
        try file.read(into: readBuffer, frameCount: min(frames, readBuffer.frameCapacity))
        let count = readBuffer.frameLength
        guard count > 0,
              let block = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: count),
              let planes = readBuffer.floatChannelData,
              let out = block.floatChannelData?[0] else { return nil }
        block.frameLength = count
        let channels = Int(readBuffer.format.channelCount)
        let length = vDSP_Length(count)
        if readBuffer.format.isInterleaved {
            vDSP_vclr(out, 1, length)
            for channel in 0..<channels {
                vDSP_vadd(out, 1, planes[0].advanced(by: channel), vDSP_Stride(channels), out, 1, length)
            }
        } else {
            out.update(from: planes[0], count: Int(count))
            for channel in 1..<max(1, channels) {
                vDSP_vadd(out, 1, planes[channel], 1, out, 1, length)
            }
        }
        if channels > 1 {
            var scale = 1 / Float(channels)
            vDSP_vsmul(out, 1, &scale, out, 1, length)
        }
        return block
    }
}
