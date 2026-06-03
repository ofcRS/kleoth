import Foundation
import AVFoundation

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

    /// Canonical file names within the output directory.
    public static let micFileName = "mic.m4a"
    public static let systemFileName = "system.m4a"
    public static let combinedFileName = "combined.m4a"

    public init() {
        self.mic = MicCapture()
        self.systemTap = SystemAudioTap()
    }

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
    /// Must be called *after* ``stop()``. Both source files are decoded to a
    /// common float32 mono representation, merged sample-for-sample into a
    /// 2-channel buffer (zero-padded to the longer source), and re-encoded as
    /// AAC.
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

    /// Decodes two sources to mono float32 and writes a single 2-channel AAC
    /// file with `channel0` on the left and `channel1` on the right.
    ///
    /// Each source is fully decoded to a mono float32 buffer, then both are
    /// copied into the corresponding channel of a non-interleaved stereo buffer
    /// (zero-padded to the longer source so the two streams stay aligned at the
    /// file start) which is written to the AAC file in capped chunks. At least
    /// one source must exist.
    static func combine(channel0: URL, channel1: URL, outputURL: URL) throws -> URL {
        let mono0 = try decodeToMono(channel0)
        let mono1 = try decodeToMono(channel1)

        guard mono0 != nil || mono1 != nil else {
            throw RecorderError.missingSourceFile(channel0)
        }

        // Balance the two channels' loudness so the combined file (in-app
        // playback) isn't lopsided when the mic is much quieter than system audio.
        ChannelAudio.normalizeLoudness(mono0)
        ChannelAudio.normalizeLoudness(mono1)

        // Common sample rate: prefer channel0's, else channel1's.
        let sampleRate = mono0?.format.sampleRate
            ?? mono1?.format.sampleRate
            ?? AudioFormat.defaultSampleRate

        guard let stereoFormat = AudioFormat.pcmFloat32(sampleRate: sampleRate, channels: 2) else {
            throw RecorderError.formatUnavailable
        }

        let settings = AudioFormat.aacSettings(sampleRate: sampleRate, channels: 2)
        let outFile = try AVAudioFile(forWriting: outputURL, settings: settings)

        let frames0 = mono0?.frameLength ?? 0
        let frames1 = mono1?.frameLength ?? 0
        let totalFrames = max(frames0, frames1)
        if totalFrames == 0 { return outputURL }

        // Write in capped chunks so we never allocate an unbounded buffer.
        let chunk: AVAudioFrameCount = 16384
        var offset: AVAudioFrameCount = 0
        while offset < totalFrames {
            let thisChunk = min(chunk, totalFrames - offset)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: thisChunk) else {
                throw RecorderError.bufferAllocationFailed
            }
            outBuffer.frameLength = thisChunk
            guard let out = outBuffer.floatChannelData else {
                throw RecorderError.bufferAllocationFailed
            }
            // Silence first so any region past a source's end stays quiet.
            memset(out[0], 0, Int(thisChunk) * MemoryLayout<Float>.size)
            memset(out[1], 0, Int(thisChunk) * MemoryLayout<Float>.size)

            copyChannel(from: mono0, into: out[0], at: offset, count: thisChunk)
            copyChannel(from: mono1, into: out[1], at: offset, count: thisChunk)

            try outFile.write(from: outBuffer)
            offset += thisChunk
        }

        return outputURL
    }

    /// Copies up to `count` mono samples from `source` starting at frame
    /// `offset` into `destination`. Frames past the end of `source` are skipped
    /// (destination was pre-zeroed).
    private static func copyChannel(
        from source: AVAudioPCMBuffer?,
        into destination: UnsafeMutablePointer<Float>,
        at offset: AVAudioFrameCount,
        count: AVAudioFrameCount
    ) {
        guard let source, let src = source.floatChannelData, offset < source.frameLength else { return }
        let available = min(count, source.frameLength - offset)
        destination.update(from: src[0].advanced(by: Int(offset)), count: Int(available))
    }

    /// Reads the whole file and converts it to a single mono float32 buffer, or
    /// returns `nil` if the file does not exist.
    private static func decodeToMono(_ url: URL) throws -> AVAudioPCMBuffer? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        if frameCount == 0 { return nil }

        // Decode the file in its native processing format first.
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw RecorderError.bufferAllocationFailed
        }
        try file.read(into: sourceBuffer)

        // Already mono float32? Use as-is.
        if sourceFormat.channelCount == 1, sourceFormat.commonFormat == .pcmFormatFloat32 {
            return sourceBuffer
        }

        guard let monoFormat = AudioFormat.pcmFloat32(sampleRate: sourceFormat.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: sourceFormat, to: monoFormat) else {
            throw RecorderError.formatUnavailable
        }
        guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: sourceBuffer.frameLength) else {
            throw RecorderError.bufferAllocationFailed
        }
        // Same sample rate, so the one-shot converter consumes the whole buffer.
        try converter.convert(to: monoBuffer, from: sourceBuffer)
        return monoBuffer
    }
}
