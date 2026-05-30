import Foundation
import AVFoundation

/// Captures microphone input via `AVAudioEngine`'s input-node tap and writes
/// it to a preopened `AVAudioFile`.
///
/// The real-time render callback installed on the input node only writes the
/// incoming buffer to a file that was opened up front; it performs no
/// allocation, locking, or `await`, as required for audio render threads. A
/// single failure flag is flipped via a heap word on error; the rich error is
/// surfaced from ``stop()`` after the engine has stopped (which establishes a
/// happens-before with the render thread).
public final class MicCapture {
    private let engine = AVAudioEngine()

    /// The destination file. Opened on `start`, released on `stop`. Only the
    /// render thread writes to it between start and stop.
    private var file: AVAudioFile?

    /// `true` while the engine is running and the tap is installed.
    private var isRunning = false

    /// Flag the render callback raises (write-only) if a buffer write fails.
    /// Read by the control thread in ``stop()`` only after `engine.stop()` has
    /// quiesced the render thread, so the callback stays lock- and
    /// allocation-free.
    private let writeFailed = RenderFlag()

    public init() {}

    /// Installs a tap on the input node and starts the engine, writing all
    /// captured audio to a freshly created file at `outputURL`.
    ///
    /// Idempotent: a second call while already running is a no-op.
    ///
    /// - Note: requires signed bundle + TCC grant (microphone permission) at
    ///   runtime; compiles without it but will fail to start when denied.
    public func start(writingTo outputURL: URL) throws {
        guard !isRunning else { return }
        writeFailed.reset()

        let input = engine.inputNode
        // Capture in the node's native output format; the AAC writer transcodes.
        let format = input.outputFormat(forBus: 0)

        // Open the destination file up front so the render thread never touches
        // the file-creation path.
        let settings = AudioFormat.aacSettings(
            sampleRate: format.sampleRate,
            channels: Int(format.channelCount)
        )
        let audioFile = try AVAudioFile(forWriting: outputURL, settings: settings)
        self.file = audioFile

        let failed = writeFailed
        let fileBox = SendableAudioFileBox(audioFile)
        // @Sendable real-time callback: write-only, no allocation/await/locks.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
            do {
                try fileBox.file.write(from: buffer)
            } catch {
                failed.raise()
            }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            // Roll back the tap/file so the instance stays reusable.
            input.removeTap(onBus: 0)
            self.file = nil
            throw error
        }
        isRunning = true
    }

    /// Backwards-compatible no-argument entry point retained from the frozen
    /// skeleton contract. Writes to a temporary `mic.m4a`; real recording uses
    /// ``start(writingTo:)`` (driven by `Recorder`).
    ///
    /// - Note: requires signed bundle + TCC grant at runtime.
    public func start() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mic-\(UUID().uuidString).m4a")
        try start(writingTo: url)
    }

    /// Removes the tap, stops the engine, and finalizes the file. Idempotent.
    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        // Quiesces the render thread; establishes ordering with the flag below.
        engine.stop()
        // Releasing the last reference flushes and closes the AAC file.
        file = nil
        isRunning = false
    }

    /// `true` if the render thread reported a buffer-write failure during the
    /// last session. Valid to read after ``stop()``.
    public var didEncounterWriteFailure: Bool { writeFailed.isRaised }
}
