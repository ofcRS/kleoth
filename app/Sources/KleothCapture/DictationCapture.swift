import Foundation
import AVFoundation
import Accelerate
import KleothCore

/// Failures a dictation capture can report to the controller.
public enum DictationCaptureError: Error, Sendable, LocalizedError {
    /// The input node vends no usable format (no channels or a zero sample
    /// rate) — typically no input device is selected at all.
    case noInputDevice
    /// Microphone access has been denied for this app in System Settings.
    case microphoneDenied
    /// `AVAudioEngine.start()` failed.
    case engineFailed(any Error)
    /// The destination file could not be created, or every buffer write failed
    /// and nothing at all was captured.
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No microphone input is available."
        case .microphoneDenied:
            return "Kleoth needs microphone access to dictate."
        case .engineFailed(let error):
            return "Couldn't start the microphone (\(error.localizedDescription))."
        case .writeFailed:
            return "Couldn't write the dictation audio."
        }
    }
}

/// A finished dictation clip on disk.
public struct DictationCaptureResult: Sendable {
    public let fileURL: URL
    public let durationSeconds: Double
    public let sampleRate: Double
    /// `true` when a device switch stopped the capture early
    /// (`.AVAudioEngineConfigurationChange`): the clip is whatever was written
    /// before the switch, so the caller must say it is partial rather than let
    /// a truncated sentence look complete.
    public let interrupted: Bool

    public init(fileURL: URL, durationSeconds: Double, sampleRate: Double, interrupted: Bool = false) {
        self.fileURL = fileURL
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
        self.interrupted = interrupted
    }
}

/// Captures one dictation utterance through its **own** `AVAudioEngine` input
/// tap, writing speech-rate (64 kbps) AAC to a temp file.
///
/// A separate engine — rather than a second tap on `MicCapture`'s bus — is the
/// only non-invasive option: `AVAudioNode` allows a single tap per bus, and a
/// dictation must be able to start while a meeting recording is already
/// running. A probe on this Mac confirmed two engines on one input device both
/// start and both receive the live stream (accepted v1 consequence: words
/// dictated during a meeting also land in that meeting's `mic.m4a`).
///
/// The render callback is allocation-free: it writes the incoming buffer to a
/// preopened `AVAudioFile` and stores into two heap words (``RenderLevel`` for
/// the meter, ``RenderCounter`` for the frame total), with a ``RenderFlag`` for
/// write failure. The rich outcome is assembled in ``stop(minimumSeconds:)``,
/// after `engine.stop()` has quiesced that thread.
///
/// The type is deliberately **not** `Sendable`: it is created by, and read only
/// from, the `@MainActor` dictation controller. The pieces the render thread
/// touches are the `@unchecked Sendable` heap words above.
///
/// The `AVAudioEngine` is **per session, not per instance**. An engine whose
/// `inputNode` has been touched keeps its input audio unit — and with it the
/// input device — alive until the engine object itself is deallocated;
/// `engine.stop()` does not let go. On a Bluetooth headset that alone pins the
/// link in the hands-free profile (16 kHz mic, phone-quality playback), so a
/// long-lived engine left every headset "uglified" after a dictation until
/// Kleoth was quit. Probed 2026-09-07 with a WH-1000XM5: the output stayed at
/// 16 kHz for as long as a stopped engine existed (even one that was never
/// started, only its input format read) and returned to 44.1 kHz within a
/// second of the engine being freed. A fresh engine costs ~150 ms more at
/// chord-down on that headset (~200 ms vs ~55 ms warm), which the controller
/// hides by acknowledging the press before the mic opens.
@available(macOS 14.4, *)
public final class DictationCapture {
    /// The engine of the session in flight. Created in `start()`, released by
    /// `quiesce()` on every exit — see the type comment for why it must die
    /// with the session.
    private var engine: AVAudioEngine?

    /// Destination for the session in flight. Released in `stop`/`cancel`,
    /// which flushes and closes the AAC file.
    private var file: AVAudioFile?

    /// URL of the session in flight, `nil` when idle.
    private var currentURL: URL?

    /// Native sample rate of the tap, captured at `start` so the duration can
    /// be derived from the frame count without touching the engine again.
    private var captureSampleRate: Double = AudioFormat.defaultSampleRate

    /// `true` between a successful `start()` and `stop`/`cancel`.
    private var running = false

    /// Raised when a device switch quiesced this session early; read out into
    /// ``DictationCaptureResult/interrupted`` by `stop`. Main-thread only (the
    /// notification is delivered on `OperationQueue.main`).
    private var interrupted = false

    /// Raised (write-only) by the render callback when a buffer write fails.
    private let writeFailed = RenderFlag()
    /// Latest buffer RMS, for the pill's level meter.
    private let level = RenderLevel()
    /// Total frames handed to the writer, for the clip duration.
    private let frames = RenderCounter()

    /// Observer for `.AVAudioEngineConfigurationChange` (device switch).
    private var configurationObserver: (any NSObjectProtocol)?

    public init() {}

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    /// `true` while a capture session is in flight.
    public var isRunning: Bool { running }

    /// Raw RMS of the latest captured buffer, clamped to `0…1`.
    ///
    /// A single-word heap read; read it from the owning (main) actor only —
    /// Swift 6 permits no other caller for a non-`Sendable` class anyway.
    public var currentLevel: Float {
        min(max(level.value, 0), 1)
    }

    /// Starts capturing into a fresh temp file and returns its URL.
    ///
    /// Every precondition is checked **before** any state is mutated, and the
    /// engine-start failure path removes the tap and deletes the file it just
    /// created, so a throw always leaves the instance idle with no temp file
    /// behind. Calling `start()` while already running returns the in-flight
    /// URL unchanged.
    @discardableResult
    public func start() throws -> URL {
        if running, let currentURL { return currentURL }

        // 1. Permission. `.denied` is the only status that can never produce
        //    audio; `.notDetermined` triggers the system prompt on engine start.
        guard AVCaptureDevice.authorizationStatus(for: .audio) != .denied else {
            throw DictationCaptureError.microphoneDenied
        }

        // 2. A fresh engine and a usable input format (no device selected ⇒
        //    0 channels / 0 Hz). The engine is a local until the session is
        //    live, so every throw below frees it — and with it the input
        //    device (see the type comment). `inputFormat`, NOT `outputFormat`:
        //    the output bus keeps the format of the last run, so after the
        //    default input device changed while an engine was idle (a
        //    Bluetooth headset connecting) it still said 48 kHz while the
        //    hardware was at 44.1 kHz, and `installTap` at that format raises
        //    an NSException — the 2026-09-06 crashes. The input bus follows
        //    the hardware (probed: stale 48 k output vs correct 44.1 k input).
        quiesce()   // never two engines
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw DictationCaptureError.noInputDevice
        }

        // 3. Destination. Opened up front so the render thread never touches
        //    the file-creation path.
        let directory = Self.tempDirectory()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw DictationCaptureError.writeFailed
        }
        let url = directory.appendingPathComponent("dictation-\(UUID().uuidString).m4a")
        let audioFile: AVAudioFile
        do {
            audioFile = try AudioFormat.openAACFile(
                at: url,
                sampleRate: format.sampleRate,
                channels: Int(format.channelCount),
                bitRate: DictationDefaults.captureBitRate
            )
        } catch {
            Self.discard(url)
            throw DictationCaptureError.writeFailed
        }

        writeFailed.reset()
        level.reset()
        frames.reset()
        interrupted = false

        guard let writer = TapWriter(file: audioFile, sourceFormat: format, bufferSize: Self.tapBufferSize) else {
            Self.discard(url)
            throw DictationCaptureError.writeFailed
        }
        do {
            try installTap(writer, on: engine)
        } catch {
            // AVFoundation refused the tap (format mismatch): a `.failed` pill,
            // not a swallowed NSException that kills the app a moment later.
            Self.discard(url)
            throw DictationCaptureError.engineFailed(error)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            // Roll all the way back: no tap, no file, no engine (it is freed
            // with this scope), instance still reusable.
            input.removeTap(onBus: 0)
            tapFormat = nil
            Self.discard(url)
            throw DictationCaptureError.engineFailed(error)
        }

        self.engine = engine
        file = audioFile
        currentURL = url
        // Frames are counted at the FILE's rate (see `TapWriter.write`), so the
        // duration stays right even if the device — and its rate — changes.
        captureSampleRate = audioFile.processingFormat.sampleRate
        running = true
        observeConfigurationChange(engine)
        return url
    }

    private static let tapBufferSize: AVAudioFrameCount = 2048

    /// Installs the render callback: one converted file write plus two
    /// heap-word stores. No allocation, no locking, no await.
    ///
    /// - Throws: ``ObjCExceptionError`` when AVFoundation raises (the format
    ///   does not match the hardware). `installTap` is documented to raise;
    ///   left uncaught, the exception is swallowed by AppKit and the process
    ///   crashes on its next main-actor check.
    private func installTap(_ writer: TapWriter, on engine: AVAudioEngine) throws {
        let failed = writeFailed
        let meter = level
        let counter = frames
        let input = engine.inputNode
        try catchingObjCExceptions {
            input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: writer.sourceFormat) { @Sendable buffer, _ in
                let written: AVAudioFrameCount
                do {
                    written = try writer.write(buffer)
                } catch {
                    failed.raise()
                    return
                }
                counter.add(UInt64(written))
                let frameLength = buffer.frameLength
                if frameLength > 0, let data = buffer.floatChannelData {
                    // `vDSP_measqv` returns the MEAN of squares, so `sqrt` of it IS
                    // the RMS — no divide-by-N is missing (see CLAUDE.md).
                    var meanSquare: Float = 0
                    vDSP_measqv(data[0], 1, &meanSquare, vDSP_Length(frameLength))
                    meter.store(meanSquare > 0 ? sqrt(meanSquare) : 0)
                }
            }
        }
        tapFormat = writer.sourceFormat   // only once AVFoundation accepted it
    }

    /// Stops the engine, finalizes the file, and describes the clip.
    ///
    /// Returns `nil` — deleting the file — when nothing was captured or the
    /// clip is shorter than `minimumSeconds` (a chord tapped by accident must
    /// never reach the network). Throws ``DictationCaptureError/writeFailed``
    /// only when the render thread reported a failure *and* no frames at all
    /// made it to disk; a partial write keeps whatever was captured.
    public func stop(minimumSeconds: Double) throws -> DictationCaptureResult? {
        guard running else { return nil }
        let url = currentURL

        quiesce()
        // Releasing the last reference flushes and closes the AAC file. The
        // flag/counter are read only after this point.
        file = nil
        running = false
        currentURL = nil
        removeConfigurationObserver()

        let frameCount = frames.value
        let didFail = writeFailed.isRaised
        let wasInterrupted = interrupted
        let rate = captureSampleRate
        level.reset()
        interrupted = false

        guard let url else { return nil }
        if didFail, frameCount == 0 {
            Self.discard(url)
            throw DictationCaptureError.writeFailed
        }

        let duration = rate > 0 ? Double(frameCount) / rate : 0
        guard frameCount > 0, duration >= minimumSeconds else {
            Self.discard(url)
            return nil
        }
        return DictationCaptureResult(
            fileURL: url,
            durationSeconds: duration,
            sampleRate: rate,
            interrupted: wasInterrupted
        )
    }

    /// Stops the engine and deletes the clip. Idempotent.
    public func cancel() {
        let url = currentURL
        quiesce()
        file = nil
        running = false
        currentURL = nil
        removeConfigurationObserver()
        level.reset()
        interrupted = false
        if let url { Self.discard(url) }
    }

    // MARK: - Preparation for upload

    /// Produces the mono, loudness- and peak-normalized file that is uploaded
    /// to Scribe, encoded at ``DictationDefaults/captureBitRate``.
    ///
    /// This reuses the tested meeting mixer with a deliberately missing second
    /// channel: `ChannelAudio.mixToMono` decodes a non-existent file to `nil`,
    /// so a single-source mix is exactly "downmix to mono at the source rate,
    /// normalize loudness, peak-normalize" with no new DSP. CPU-bound — call it
    /// from `Task.detached`, never on the main actor.
    ///
    /// - Parameter outputURL: where to write; defaults to a fresh
    ///   ``preparedURL(for:)``. Pass one when the caller must be able to delete
    ///   the file without waiting for this call to return (see
    ///   `DictationController.shutdown()`).
    /// - Returns: a sibling `prep-<uuid>.m4a` next to `raw`.
    /// - Throws: `ChannelAudio.AudioError` or an `AVAudioFile` error; the
    ///   controller surfaces it on the pill.
    public static func prepareForUpload(_ raw: URL, outputURL: URL? = nil) throws -> URL {
        let output = outputURL ?? preparedURL(for: raw)
        return try ChannelAudio.mixToMono(
            channel0: raw,
            channel1: URL(fileURLWithPath: "/nonexistent-dictation-channel"),
            outputURL: output,
            bitRate: DictationDefaults.captureBitRate
        )
    }

    /// The destination `prepareForUpload` writes to: a fresh `prep-<uuid>.m4a`
    /// beside `raw`. Exposed so a caller can register the path for cleanup
    /// *before* the (detached, CPU-bound) preparation starts.
    public static func preparedURL(for raw: URL) -> URL {
        raw
            .deletingLastPathComponent()
            .appendingPathComponent("prep-\(UUID().uuidString).m4a")
    }

    /// Deletes a temp clip, ignoring "already gone". Safe to call twice.
    public static func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// `$TMPDIR/kleoth-dictation/` — every raw and prepared clip lives here and
    /// nowhere else. Dictation audio is never kept.
    public static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-dictation", isDirectory: true)
    }

    /// Deletes clips left behind by a crash. Run once at launch.
    ///
    /// Only files whose modification date is older than `seconds` are removed,
    /// so a capture in flight in another (or this) process is never touched.
    public static func sweepStaleClips(olderThan seconds: TimeInterval = 3600) {
        let manager = FileManager.default
        let directory = tempDirectory()
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-seconds)
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate else { continue }
            if modified < cutoff {
                try? manager.removeItem(at: entry)
            }
        }
    }

    // MARK: - Engine lifecycle

    /// Removes the tap, stops the engine and **releases it** — the release is
    /// what hands a Bluetooth headset back to its music profile (see the type
    /// comment). Idempotent; a no-op when no engine is alive.
    private func quiesce() {
        guard let engine else { return }
        if tapFormat != nil {
            engine.inputNode.removeTap(onBus: 0)
            tapFormat = nil
        }
        engine.stop()
        self.engine = nil
    }

    /// Watches for a device change under the live session — a Bluetooth
    /// headset switching profiles ~0.1 s after its mic is opened (every cold
    /// start on such a headset), AirPods connecting, a dock unplugged.
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

    /// The device (or its format) changed under a live session: reinstall the
    /// tap at the node's new format and restart the engine, converting into
    /// the already-open file (`TapWriter`) so the clip continues seamlessly.
    /// A change that left the engine running at the same format — the usual
    /// Bluetooth profile settle — is a no-op. Only when the restart itself
    /// fails (no input device left, converter unavailable) does the session
    /// quiesce with `interrupted` set, keeping whatever was captured; the
    /// meter is zeroed then because the owner polls `currentLevel` at 20 Hz
    /// and a frozen last-RMS reading keeps the pill looking live.
    private func handleConfigurationChange() {
        guard running, let engine, let file else { return }
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
            giveUpAfterConfigurationChange()
            return
        }
        do {
            try installTap(writer, on: engine)
        } catch {
            giveUpAfterConfigurationChange()
            return
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            giveUpAfterConfigurationChange()
        }
    }

    /// The session keeps what it captured but the engine is released now —
    /// a dead engine would still pin the headset's profile until `stop()`.
    private func giveUpAfterConfigurationChange() {
        quiesce()
        interrupted = true
        level.reset()
    }

    /// The format the current tap was installed with.
    private var tapFormat: AVAudioFormat?

    private func removeConfigurationObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    /// Carries a weak reference to the owning capture across the `@Sendable`
    /// notification handler.
    ///
    /// `@unchecked Sendable` is sound because the box does nothing but hand the
    /// reference back on `OperationQueue.main` — the very thread the
    /// `@MainActor` controller that owns this `DictationCapture` runs on — so
    /// the capture is still only ever touched from one thread.
    private final class OwnerBox: @unchecked Sendable {
        weak var owner: DictationCapture?
        init(_ owner: DictationCapture) { self.owner = owner }
    }
}
