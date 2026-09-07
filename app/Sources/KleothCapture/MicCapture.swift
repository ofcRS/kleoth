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
    /// The engine of the session in flight — created in `start(writingTo:)`,
    /// released in `stop()`. Per session for the same reason as
    /// `DictationCapture.engine`: a stopped-but-alive engine keeps the input
    /// device open, which holds a Bluetooth headset in its hands-free
    /// (phone-quality) profile. The `Recorder` that owns this capture outlives
    /// `stop()` by the whole 2-channel combine, so the release cannot be
    /// left to deinit.
    private var engine: AVAudioEngine?

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

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

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

        // A local until the session is live: every throw below frees it.
        releaseEngine()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Capture at the HARDWARE format (`inputFormat`); the AAC writer
        // transcodes. `outputFormat` keeps the previous run's format after the
        // default input device changed while the engine was idle, and a tap at
        // that stale format raises — see `DictationCapture.start()`.
        let format = input.inputFormat(forBus: 0)

        // Open the destination file up front so the render thread never touches
        // the file-creation path.
        let audioFile = try AudioFormat.openAACFile(
            at: outputURL,
            sampleRate: format.sampleRate,
            channels: Int(format.channelCount)
        )
        guard let writer = TapWriter(file: audioFile, sourceFormat: format, bufferSize: Self.tapBufferSize) else {
            throw ChannelAudio.AudioError.formatUnavailable
        }
        try installTap(writer, on: engine)   // an AVFoundation refusal surfaces as a Swift error, nothing to roll back
        self.file = audioFile

        do {
            engine.prepare()
            try engine.start()
        } catch {
            // Roll back the tap/file so the instance stays reusable (the
            // engine dies with this scope).
            input.removeTap(onBus: 0)
            tapFormat = nil
            self.file = nil
            throw error
        }
        self.engine = engine
        isRunning = true
        observeConfigurationChange(engine)
    }

    private static let tapBufferSize: AVAudioFrameCount = 4096

    /// @Sendable real-time callback: one (converted) file write, no
    /// allocation/await/locks.
    ///
    /// - Throws: ``ObjCExceptionError`` when AVFoundation raises on a format
    ///   that does not match the hardware (see `DictationCapture.installTap`).
    private func installTap(_ writer: TapWriter, on engine: AVAudioEngine) throws {
        let failed = writeFailed
        let input = engine.inputNode
        try catchingObjCExceptions {
            input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: writer.sourceFormat) { @Sendable buffer, _ in
                do {
                    _ = try writer.write(buffer)
                } catch {
                    failed.raise()
                }
            }
        }
        tapFormat = writer.sourceFormat   // only once AVFoundation accepted it
    }

    /// Removes the tap (if any), stops the engine and releases it. Idempotent.
    private func releaseEngine() {
        guard let engine else { return }
        if tapFormat != nil {
            engine.inputNode.removeTap(onBus: 0)
            tapFormat = nil
        }
        engine.stop()
        self.engine = nil
    }

    // MARK: - Device changes

    /// The format the current tap was installed with.
    private var tapFormat: AVAudioFormat?
    private var configurationObserver: (any NSObjectProtocol)?

    private func observeConfigurationChange(_ engine: AVAudioEngine) {
        removeConfigurationObserver()
        let box = OwnerBox(self)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { _ in
            box.owner?.handleConfigurationChange()
        }
    }

    private func removeConfigurationObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    /// Same policy as `DictationCapture`: a Bluetooth headset switching
    /// profiles right after its mic is opened, or a device swapped
    /// mid-meeting, stops the engine or changes the node's format. Reinstall
    /// the tap at the new format and restart; `TapWriter` converts into the
    /// file that is already open, so `mic.m4a` continues instead of ending
    /// silently at the switch. If no input is left, the file simply stops
    /// growing (the system channel keeps recording).
    private func handleConfigurationChange() {
        guard isRunning, let engine, let file else { return }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)   // the hardware format — see `start()`
        if engine.isRunning, let current = tapFormat, TapWriter.matches(format, current) {
            return
        }
        if tapFormat != nil {
            input.removeTap(onBus: 0)
            tapFormat = nil
        }
        engine.stop()
        guard format.channelCount > 0, format.sampleRate > 0,
              let writer = TapWriter(file: file, sourceFormat: format, bufferSize: Self.tapBufferSize) else {
            releaseEngine()   // no input left; don't keep the device pinned
            return
        }
        do {
            try installTap(writer, on: engine)
        } catch {
            releaseEngine()   // no input left worth reopening; the system channel keeps recording
            return
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            releaseEngine()
        }
    }

    /// Weak owner reference for the `@Sendable` notification handler.
    private final class OwnerBox: @unchecked Sendable {
        weak var owner: MicCapture?
        init(_ owner: MicCapture) { self.owner = owner }
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
        removeConfigurationObserver()
        // Quiesces the render thread (ordering with the flag below) and frees
        // the engine, which is what lets a headset leave hands-free mode.
        releaseEngine()
        // Releasing the last reference flushes and closes the AAC file.
        file = nil
        isRunning = false
    }

    /// `true` if the render thread reported a buffer-write failure during the
    /// last session. Valid to read after ``stop()``.
    public var didEncounterWriteFailure: Bool { writeFailed.isRaised }
}
