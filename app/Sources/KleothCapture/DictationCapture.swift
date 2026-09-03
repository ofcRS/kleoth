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

    public init(fileURL: URL, durationSeconds: Double, sampleRate: Double) {
        self.fileURL = fileURL
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
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
@available(macOS 14.4, *)
public final class DictationCapture {
    private let engine = AVAudioEngine()

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

    /// `true` once the engine has been stopped and the tap removed for this
    /// session — either by `stop`/`cancel` or by a configuration change.
    /// Starts `true` so `quiesce()` is a no-op before the first `start()`.
    private var engineQuiesced = true

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

        // 2. A usable input format (no device selected ⇒ 0 channels / 0 Hz).
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
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
        let settings = AudioFormat.aacSettings(
            sampleRate: format.sampleRate,
            channels: Int(format.channelCount),
            bitRate: DictationDefaults.captureBitRate
        )
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            Self.discard(url)
            throw DictationCaptureError.writeFailed
        }

        writeFailed.reset()
        level.reset()
        frames.reset()

        let failed = writeFailed
        let meter = level
        let counter = frames
        let fileBox = SendableAudioFileBox(audioFile)
        // @Sendable real-time callback: one file write plus two heap-word
        // stores. No allocation, no locking, no await.
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in
            do {
                try fileBox.file.write(from: buffer)
            } catch {
                failed.raise()
                return
            }
            let frameLength = buffer.frameLength
            counter.add(UInt64(frameLength))
            if frameLength > 0, let data = buffer.floatChannelData {
                // `vDSP_measqv` returns the MEAN of squares, so `sqrt` of it IS
                // the RMS — no divide-by-N is missing (see CLAUDE.md).
                var meanSquare: Float = 0
                vDSP_measqv(data[0], 1, &meanSquare, vDSP_Length(frameLength))
                meter.store(meanSquare > 0 ? sqrt(meanSquare) : 0)
            }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            // Roll all the way back: no tap, no file, instance still reusable.
            input.removeTap(onBus: 0)
            Self.discard(url)
            throw DictationCaptureError.engineFailed(error)
        }

        file = audioFile
        currentURL = url
        captureSampleRate = format.sampleRate
        running = true
        engineQuiesced = false
        observeConfigurationChange()
        return url
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
        let rate = captureSampleRate
        level.reset()

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
        return DictationCaptureResult(fileURL: url, durationSeconds: duration, sampleRate: rate)
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
    /// - Returns: a sibling `prep-<uuid>.m4a` next to `raw`.
    /// - Throws: `ChannelAudio.AudioError` or an `AVAudioFile` error; the
    ///   controller surfaces it on the pill.
    public static func prepareForUpload(_ raw: URL) throws -> URL {
        let output = raw
            .deletingLastPathComponent()
            .appendingPathComponent("prep-\(UUID().uuidString).m4a")
        return try ChannelAudio.mixToMono(
            channel0: raw,
            channel1: URL(fileURLWithPath: "/nonexistent-dictation-channel"),
            outputURL: output,
            bitRate: DictationDefaults.captureBitRate
        )
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

    /// Removes the tap and stops the engine exactly once per session.
    private func quiesce() {
        guard !engineQuiesced else { return }
        engineQuiesced = true
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Watches for a mid-utterance device switch (AirPods connecting, dock
    /// unplugged). The input node's format changes underneath the tap, which
    /// the preopened AAC writer cannot accept, so the only safe response is to
    /// quiesce immediately and keep whatever was captured — `stop()` still
    /// returns it if it clears the minimum.
    private func observeConfigurationChange() {
        removeConfigurationObserver()
        let box = OwnerBox(self)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { _ in
            box.owner?.quiesce()
        }
    }

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
