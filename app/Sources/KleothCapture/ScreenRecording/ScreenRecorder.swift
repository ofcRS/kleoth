import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import KleothCore
import ScreenCaptureKit
import os

/// What a running session has produced so far — the `screenrec` probe's
/// per-second line, and the numbers `stop` folds into the summary.
public struct ScreenRecorderStats: Sendable, Equatable {
    public var pixelSize: CGSize = .zero
    public var videoBitRate: Int = 0
    /// Host time of the session origin (the first `.screen` sample), or 0
    /// before one has arrived. `screenrec` anchors its record deadline here so
    /// "10 s" means 10 s **of movie**, not 10 s of wall clock after `start()`
    /// returned — ScreenCaptureKit hands over the first frame with a PTS that
    /// is already ~0.2 s in the past.
    public var sessionOriginHostTime: UInt64 = 0
    public var videoAppended: Int = 0
    public var videoDropped: Int = 0
    public var audioBlocks: Int = 0
    public var audioDropped: Int = 0
    public var micCaptured: Bool = false
    public var micGaps: [ScreenRecordingSummary.MicGap] = []
    public var micRealFrames: Int64 = 0
    public var micTotalFrames: Int64 = 0
    /// Frames the microphone lane discarded because they arrived after their
    /// position had already been mixed.
    public var micLateFrames: Int64 = 0
    public var systemLateFrames: Int64 = 0
    /// Writer duration (last appended video PTS − session start).
    public var duration: TimeInterval = 0
    public var writerFailure: String?
}

/// One screen-recording session: the `SCStream`, the microphone engine, the mix
/// pump, the movie writer, and the three serial queues they run on (design
/// §3.2, §4, §5).
///
/// `@MainActor` because its public API is the controller's; the ScreenCaptureKit
/// / audio-tap / writer callbacks run on those queues inside `@unchecked
/// Sendable` sink objects (the `TapWriter` / `RenderLevel` precedent in
/// `AudioFormat.swift`) that only ever hop RESULTS back to the main actor.
/// `finishWriting` is awaited through its completion-handler form — never the
/// synchronous one (AVAssetWriter.h:384). One fresh instance per session, like
/// `Recorder` (Recorder.swift:24-44).
@MainActor
public final class ScreenRecorder {
    private static let log = Logger(subsystem: "dev.kleoth", category: "ScreenRecording")

    private let configuration: ScreenRecordingConfiguration
    private let clock = HostClockMath()

    // Three serial queues, the way Apple's ScreenCaptureKit sample splits them:
    // one per stream output, plus the writer's own inside `MovieWriter`.
    private let videoQueue = DispatchQueue(label: "dev.kleoth.screenrecording.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "dev.kleoth.screenrecording.audio", qos: .userInteractive)

    private let eventStream: AsyncStream<ScreenRecorderEvent>
    private let eventSink: AsyncStream<ScreenRecorderEvent>.Continuation
    /// Resolves once the first `.screen` sample of ANY status arrives.
    private let firstFrames: AsyncStream<UInt64>
    private let firstFrameSink: AsyncStream<UInt64>.Continuation

    private var stream: SCStream?
    private var output: StreamOutput?
    private var writer: MovieWriter?
    private var gate: VideoFrameGate?
    private var pump: AudioMixPump?
    private var microphone: MicrophoneSource?
    private var rings: AudioRingBox?

    /// §5.3's optional periodic re-append. Off by default
    /// (`ScreenRecordingDefaults.keepaliveInterval` is nil); the stop-time
    /// re-append alone is what keeps the tracks the same length.
    private var keepaliveTimer: DispatchSourceTimer?

    private var started = false
    private var stopped = false
    private var finalSummary: ScreenRecordingSummary?
    private var resolvedPixelSize: CGSize = .zero
    private var resolvedBitRate = 0
    private var writerFailure: String?
    /// The last readings taken before the writer and pump were released, so
    /// `stats` still answers honestly after `stop()`.
    private var lastWriterStats: MovieWriter.Stats?
    private var lastPumpStats: AudioMixPump.Stats?
    private var lastGateDropped = 0
    private var lastRingDropped: (mic: Int64, system: Int64) = (0, 0)

    public init(configuration: ScreenRecordingConfiguration) {
        self.configuration = configuration
        let events = AsyncStream<ScreenRecorderEvent>.makeStream(bufferingPolicy: .unbounded)
        eventStream = events.stream
        eventSink = events.continuation
        let frames = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingNewest(1))
        firstFrames = frames.stream
        firstFrameSink = frames.continuation
    }

    /// Live counters — the `screenrec` probe's per-second line.
    ///
    /// It reads the writer's and pump's state through a brief `sync` onto their
    /// queues, so it is a diagnostic accessor, not something to poll at frame
    /// rate from the main actor.
    public var stats: ScreenRecorderStats {
        var out = ScreenRecorderStats()
        out.pixelSize = resolvedPixelSize
        out.videoBitRate = resolvedBitRate
        out.videoDropped = writer != nil ? gateDropped() : lastGateDropped
        if let snapshot = writer?.snapshot() ?? lastWriterStats {
            out.videoAppended = snapshot.videoAppended
            out.videoDropped += snapshot.videoDropped
            out.audioBlocks = snapshot.audioAppended
            out.audioDropped = snapshot.audioDropped
            out.duration = snapshot.duration
            out.writerFailure = snapshot.failure ?? writerFailure
        } else {
            out.writerFailure = writerFailure
        }
        if let snapshot = pump?.snapshot() ?? lastPumpStats {
            out.micCaptured = snapshot.micCaptured
            out.micGaps = snapshot.micGaps
            out.micRealFrames = snapshot.micRealFrames
            out.micTotalFrames = snapshot.micTotalFrames
            out.audioDropped += snapshot.blocksDropped
        }
        if let rings {
            let snapshot = audioQueue.sync { (rings.origin ?? 0, rings.micDropped, rings.systemDropped) }
            out.sessionOriginHostTime = snapshot.0
            out.micLateFrames = snapshot.1
            out.systemLateFrames = snapshot.2
        } else {
            out.micLateFrames = lastRingDropped.mic
            out.systemLateFrames = lastRingDropped.system
        }
        return out
    }

    // MARK: - Start

    /// Resolves `SCShareableContent` (under `withDeadline` — it can hang while
    /// the TCC dialog is up, and it ignores cancellation), builds the filter +
    /// stream configuration (§5.2),
    /// opens the writer, starts capture, and returns after the first `.screen`
    /// sample of any status — or throws `.noFirstFrame` after
    /// `firstFrameTimeout`, deleting the file.
    public func start() async throws {
        guard !started else { throw ScreenRecorderError.alreadyStarted }
        started = true

        let content = try await shareableContent()
        guard let display = content.value.displays.first(where: { $0.displayID == configuration.target.displayID })
        else {
            throw ScreenRecorderError.noDisplay
        }

        let filter = try makeFilter(display: display, content: content.value)
        let streamConfiguration = makeStreamConfiguration(filter: filter, display: display)
        resolvedPixelSize = CGSize(width: streamConfiguration.width, height: streamConfiguration.height)
        resolvedBitRate = CaptureGeometry.videoBitRate(pixelSize: resolvedPixelSize)

        try openWriter()
        try await startCapture(filter: filter, configuration: streamConfiguration)
        startMicrophoneIfWanted()
        startKeepaliveIfWanted()

        if let timeout = configuration.firstFrameTimeout {
            do {
                let stream = firstFrames
                _ = try await withTimeout(seconds: timeout) {
                    var iterator = stream.makeAsyncIterator()
                    return await iterator.next()
                }
            } catch {
                await abandon()
                throw ScreenRecorderError.noFirstFrame
            }
        }
    }

    // MARK: - Stop

    /// Idempotent. Stops the stream + mic, appends the retained last frame at
    /// the stop time (§5.3), flushes the mix pump, awaits `finishWriting`, and
    /// renames to the final URL. The WAIT is bounded by `finalizeTimeout`
    /// (`withDeadline` — `finishWriting` itself cannot be cancelled); a finish
    /// that lands after the deadline still renames the movie in the background.
    @discardableResult
    public func stop(reason: ScreenRecordingStopReason) async throws -> ScreenRecordingSummary {
        if let finalSummary { return finalSummary }
        guard started, let writer else { throw ScreenRecorderError.nothingCaptured }
        guard !stopped else { throw ScreenRecorderError.nothingCaptured }
        stopped = true
        // The session is over however this call ends — a consumer looping over
        // `events` must not be left hanging on a throw (`.nothingCaptured`,
        // `.finalizeTimedOut`) either.
        defer { eventSink.finish() }

        // The instant everything must reach. Taken before the (async) teardown
        // so a slow `stopCapture` cannot stretch the movie.
        let stopHostTime = mach_absolute_time()

        microphone?.stop()
        microphone = nil
        stopKeepalive()
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        // The session origin is `AudioRingBox` state, and that box is
        // audio-queue only — read it there once rather than reaching into it
        // from the main actor.
        let origin: (hostTime: UInt64, pts: CMTime)? = rings.flatMap { rings in
            audioQueue.sync { rings.origin.map { ($0, rings.originPTS) } }
        }

        // Video: retime the retained last frame to the stop instant so a
        // static tail is not truncated (§5.3).
        if let gate, let origin {
            let elapsed = clock.seconds(fromHostTime: origin.hostTime, to: stopHostTime)
            let stopPTS = CMTimeAdd(origin.pts, CMTime(seconds: max(0, elapsed), preferredTimescale: 600))
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                videoQueue.async {
                    gate.appendFinalFrame(at: stopPTS)
                    gate.releaseRetainedFrame()
                    continuation.resume()
                }
            }
        }

        // Audio: flush every block up to the same instant.
        var pumpStats = AudioMixPump.Stats()
        if let pump, let origin {
            let stopPosition = clock.samplePosition(
                hostTime: stopHostTime,
                origin: origin.hostTime,
                sampleRate: ScreenRecordingDefaults.audioSampleRate
            )
            pumpStats = await pump.stop(at: stopPosition)
        }
        lastPumpStats = pumpStats
        lastGateDropped = gateDropped()
        if let rings { lastRingDropped = (ringCount(rings, mic: true), ringCount(rings, mic: false)) }
        self.pump = nil

        // `finishWriting` ignores cancellation, so the deadline can only stop US
        // waiting — `withDeadline` (not `withTimeout`, which would sit on the
        // non-cancellable child and make the bound a label) leaves the finish
        // running and hands the wait back after `finalizeTimeout`.
        let finish = Task { try await writer.finish() }
        let writerStats: MovieWriter.Stats
        do {
            writerStats = try await withDeadline(seconds: ScreenRecordingDefaults.finalizeTimeout) {
                try await finish.value
            }
        } catch is KleothTimeoutError {
            Self.log.error("screen recording finalize exceeded \(ScreenRecordingDefaults.finalizeTimeout, privacy: .public) s")
            renameWhenFinishLands(finish, outputURL: configuration.outputURL)
            throw ScreenRecorderError.finalizeTimedOut
        }
        lastWriterStats = writerStats

        guard writerStats.videoAppended > 0 else {
            try? FileManager.default.removeItem(at: configuration.outputURL)
            throw ScreenRecorderError.nothingCaptured
        }

        let finalURL = ScreenRecordingFileNaming.finalURL(for: configuration.outputURL)
        let url = rename(configuration.outputURL, to: finalURL)
        let summary = ScreenRecordingSummary(
            url: url,
            duration: await Self.probedDuration(of: url) ?? writerStats.duration,
            fileSizeBytes: fileSize(of: url),
            videoFramesAppended: writerStats.videoAppended,
            droppedFrames: writerStats.videoDropped + gateDropped(),
            micCaptured: pumpStats.micCaptured,
            micGaps: pumpStats.micGaps,
            stopReason: reason
        )
        finalSummary = summary
        return summary
    }

    /// Mid-session facts (first frame, mic gaps, a system-initiated stop, a
    /// writer failure). Finishes when the session does.
    public var events: AsyncStream<ScreenRecorderEvent> { eventStream }

    // MARK: - Shareable content + filter

    /// `SCShareableContent` is not `Sendable`; the box carries it across the
    /// timeout's task boundary. It is read only on the main actor afterwards.
    private struct ContentBox: @unchecked Sendable {
        let value: SCShareableContent
    }

    private func shareableContent() async throws -> ContentBox {
        do {
            // `withDeadline`, not `withTimeout`: the completion-handler import
            // ignores cancellation, so a task group would wait out the TCC
            // dialog anyway. The abandoned query is harmless — it only reads.
            return try await withDeadline(seconds: 5) {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true
                )
                return ContentBox(value: content)
            }
        } catch is KleothTimeoutError {
            throw ScreenRecorderError.shareableContentTimedOut
        } catch {
            throw Self.mapped(error)
        }
    }

    /// The filter that keeps Kleoth's own windows — the pill, the region picker
    /// overlays, the popover — out of the recording (§5.2).
    ///
    /// Whole-application exclusion, not per-window, because the filter is by
    /// owning process and therefore also covers windows created *after*
    /// `startCapture`. The controller shows the pill BEFORE calling `start()`
    /// precisely so Kleoth is in this snapshot. The documented consequence: a
    /// user cannot demo Kleoth itself in a recording (§9 follow-up).
    ///
    /// A bare `screenrec` has no bundle identifier and skips the exclusion —
    /// there is no Kleoth UI in that process to hide.
    private func makeFilter(display: SCDisplay, content: SCShareableContent) throws -> SCContentFilter {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            return SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }
        if let application = content.applications.first(where: { $0.bundleIdentifier == bundleID }) {
            return SCContentFilter(display: display, excludingApplications: [application], exceptingWindows: [])
        }

        // Fallback: exclude our own windows by process id.
        let pid = getpid()
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == pid }
        guard !ownWindows.isEmpty else {
            Self.log.error("Kleoth is absent from the shareable-content snapshot; refusing to record")
            throw ScreenRecorderError.selfNotInShareableContent
        }
        Self.log.warning("Kleoth was not in SCShareableContent.applications; excluding \(ownWindows.count) window(s) by pid")
        return SCContentFilter(display: display, excludingWindows: ownWindows)
    }

    private func makeStreamConfiguration(filter: SCContentFilter, display: SCDisplay) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let scale = filter.pointPixelScale > 0 ? CGFloat(filter.pointPixelScale) : 1

        let sourcePoints: CGSize
        if let rect = self.configuration.target.sourceRect, rect.width > 0, rect.height > 0 {
            configuration.sourceRect = rect
            sourcePoints = rect.size
        } else {
            sourcePoints = CGSize(width: display.width, height: display.height)
        }

        let pixelSize = CaptureGeometry.outputPixelSize(
            sourcePoints: sourcePoints,
            pointPixelScale: scale,
            maxLongEdge: ScreenRecordingDefaults.maxLongEdgePixels
        )
        configuration.width = Int(pixelSize.width)
        configuration.height = Int(pixelSize.height)
        configuration.minimumFrameInterval = CMTime(
            value: 1, timescale: ScreenRecordingDefaults.framesPerSecond
        )
        configuration.queueDepth = 6
        configuration.showsCursor = true
        // BGRA: correctness first — no color-matrix tagging to get wrong, and
        // the RGB→YUV pass lives inside VideoToolbox on this hardware (§5.2).
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.capturesAudio = true
        configuration.sampleRate = Int(ScreenRecordingDefaults.audioSampleRate)
        configuration.channelCount = Int(ScreenRecordingDefaults.audioChannels)
        // Mirrors the meeting tap's exclude-self: Kleoth's own chime or player
        // never leaks into a recording.
        configuration.excludesCurrentProcessAudio = true
        return configuration
    }

    // MARK: - Wiring

    private func openWriter() throws {
        let directory = configuration.outputURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ScreenRecorderError.writerSetupFailed(error.localizedDescription)
        }
        try? FileManager.default.removeItem(at: configuration.outputURL)

        let sink = eventSink
        let writer = try MovieWriter(
            outputURL: configuration.outputURL,
            pixelSize: resolvedPixelSize,
            videoBitRate: resolvedBitRate,
            fragmentInterval: configuration.fragmentInterval,
            onFailure: { message in sink.yield(.writerFailed(message)) }
        )
        self.writer = writer

        let capacity = Int(ScreenRecordingDefaults.ringSeconds * ScreenRecordingDefaults.audioSampleRate)
        let rings = AudioRingBox(
            capacityFrames: capacity,
            channels: Int(ScreenRecordingDefaults.audioChannels),
            tolerance: ScreenRecordingDefaults.mixAlignToleranceFrames
        )
        self.rings = rings

        let pump = AudioMixPump(
            queue: audioQueue,
            rings: rings,
            writer: writer,
            clock: clock,
            sampleRate: ScreenRecordingDefaults.audioSampleRate,
            blockFrames: ScreenRecordingDefaults.mixBlockFrames,
            channels: Int(ScreenRecordingDefaults.audioChannels),
            latency: ScreenRecordingDefaults.mixLatency,
            onGapBegan: { at in sink.yield(.micGapBegan(at: at)) },
            onGapEnded: { at in sink.yield(.micGapEnded(at: at)) }
        )
        self.pump = pump

        // The session origin is decided on the video queue (the first `.screen`
        // sample) and consumed on the audio queue, so it is published with one
        // hop and is audio-queue-only from then on.
        let audioQueue = audioQueue
        let firstFrameSink = firstFrameSink
        let gate = VideoFrameGate(writer: writer) { hostTime in
            let pts = CMClockMakeHostTimeFromSystemUnits(hostTime)
            audioQueue.async {
                rings.setOrigin(hostTime: hostTime, pts: pts)
                pump.start()
            }
            firstFrameSink.yield(hostTime)
            sink.yield(.firstFrame(hostTime: hostTime))
        }
        self.gate = gate
    }

    private func startCapture(filter: SCContentFilter, configuration streamConfiguration: SCStreamConfiguration) async throws {
        guard let gate, let rings else { throw ScreenRecorderError.writerSetupFailed("no writer") }
        let sink = eventSink
        let output = StreamOutput(
            gate: gate,
            systemAudio: SystemAudioSink(
                rings: rings, clock: clock, sampleRate: ScreenRecordingDefaults.audioSampleRate
            ),
            onStreamStopped: { message in
                sink.yield(.streamStopped(reason: message, systemInitiated: true))
            }
        )
        self.output = output

        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: videoQueue)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioQueue)
            try await stream.startCapture()
        } catch {
            await abandon()
            throw Self.mapped(error)
        }
        self.stream = stream
    }

    private func startMicrophoneIfWanted() {
        guard configuration.captureMicrophone, let rings else { return }
        let sink = eventSink
        let microphone = MicrophoneSource(
            audioQueue: audioQueue,
            rings: rings,
            clock: clock,
            sampleRate: ScreenRecordingDefaults.audioSampleRate,
            onStarted: { sink.yield(.micStarted) },
            onLost: { reason in sink.yield(.micLost(reason)) }
        )
        do {
            try microphone.start()
            self.microphone = microphone
        } catch {
            // A recording without a mic is still a recording (error matrix #5).
            Self.log.error("screen recording microphone unavailable: \(error.localizedDescription, privacy: .public)")
            eventSink.yield(.micLost(error.localizedDescription))
        }
    }

    /// §5.3's optional keepalive: re-append the retained last frame every
    /// `keepaliveInterval`, so a screen that has not changed for minutes still
    /// gets samples in the middle of the track rather than only at the stop.
    /// It obeys the gate's monotonic guard, so a live screen is unaffected
    /// (its own frames are always newer).
    ///
    /// Deliberately off by default — the default is `nil` and only §8 #19
    /// (a 60 s static stretch that scrubs badly) would turn it on.
    private func startKeepaliveIfWanted() {
        guard let interval = ScreenRecordingDefaults.keepaliveInterval, interval > 0, let gate else { return }
        let timer = DispatchSource.makeTimerSource(queue: videoQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
        timer.setEventHandler {
            gate.appendFinalFrame(at: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        keepaliveTimer = timer
        timer.resume()
    }

    private func stopKeepalive() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
    }

    // MARK: - Teardown helpers

    /// Tears a half-built session down and deletes the file. Used by every
    /// `start()` failure path — a `.recording.mp4` left behind would be swept
    /// as a "recovered" recording on the next launch.
    private func abandon() async {
        microphone?.stop()
        microphone = nil
        stopKeepalive()
        if let stream { try? await stream.stopCapture() }
        stream = nil
        _ = await pump?.stop(at: 0)
        pump = nil
        writer?.cancel()
        writer = nil
        gate = nil
        rings = nil
        stopped = true
        try? FileManager.default.removeItem(at: configuration.outputURL)
        eventSink.finish()
    }

    /// A finalize that blew `finalizeTimeout` is still running: when it lands,
    /// give the movie its final name anyway (or delete an empty one), so a
    /// slow-but-successful finish is a normal recording on disk instead of a
    /// `.recording.mp4` the next launch sweeps as "recovered". If the app quits
    /// first the file keeps its in-progress name and the sweep still finds it.
    private func renameWhenFinishLands(
        _ finish: Task<MovieWriter.Stats, Error>,
        outputURL: URL
    ) {
        let log = Self.log
        Task.detached {
            guard let stats = try? await finish.value else { return }
            guard stats.videoAppended > 0 else {
                try? FileManager.default.removeItem(at: outputURL)
                return
            }
            let finalURL = ScreenRecordingFileNaming.finalURL(for: outputURL)
            guard !FileManager.default.fileExists(atPath: finalURL.path) else { return }
            do {
                try FileManager.default.moveItem(at: outputURL, to: finalURL)
                log.notice("late screen recording finalize landed; renamed to its final name")
            } catch {
                log.error("couldn't rename a late-finalized recording: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func rename(_ url: URL, to destination: URL) -> URL {
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        } catch {
            Self.log.error("couldn't rename the recording: \(error.localizedDescription, privacy: .public)")
            return url
        }
    }

    private func fileSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    /// Wall-clock duration read back from the finished file — the same
    /// "trust the container, not the producer" rule meetings follow
    /// (`AudioProbe.durationSeconds`).
    static func probedDuration(of url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    private func gateDropped() -> Int {
        guard let gate else { return 0 }
        return videoQueue.sync { gate.droppedCount }
    }

    private func ringCount(_ rings: AudioRingBox, mic: Bool) -> Int64 {
        audioQueue.sync { mic ? rings.micDropped : rings.systemDropped }
    }

    private static func mapped(_ error: any Error) -> any Error {
        let nsError = error as NSError
        // SCStreamErrorUserDeclined
        if nsError.code == -3801 { return ScreenRecorderError.userDeclined }
        if let recorderError = error as? ScreenRecorderError { return recorderError }
        return ScreenRecorderError.writerSetupFailed(nsError.localizedDescription)
    }
}

/// The ScreenCaptureKit callback surface. Both `SCStreamOutput` methods are
/// called on the queues the stream was given (`.screen` → the video queue,
/// `.audio` → the audio queue), which is exactly the affinity `VideoFrameGate`
/// and `SystemAudioSink` document. `@unchecked Sendable` on that argument.
private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let gate: VideoFrameGate
    private let systemAudio: SystemAudioSink
    private let onStreamStopped: @Sendable (String) -> Void

    init(
        gate: VideoFrameGate,
        systemAudio: SystemAudioSink,
        onStreamStopped: @escaping @Sendable (String) -> Void
    ) {
        self.gate = gate
        self.systemAudio = systemAudio
        self.onStreamStopped = onStreamStopped
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            gate.handle(sampleBuffer)
        case .audio:
            systemAudio.handle(sampleBuffer)
        default:
            break
        }
    }

    /// The "Stop Sharing" chip, a display going to sleep, a lost screen — any
    /// end that was not our own `stop(reason:)` (error matrix #12).
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStreamStopped(error.localizedDescription)
    }
}
