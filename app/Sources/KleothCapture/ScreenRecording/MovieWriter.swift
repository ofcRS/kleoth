import AVFoundation
import CoreGraphics
import Foundation
import KleothCore
import os

/// The `AVAssetWriter` half of a screen-recording session: one H.264 video
/// input, one AAC audio input, a fragmented MP4 on disk (design §3.2, §5.5).
///
/// **Threading.** Every stored property below is touched ONLY on `queue`, the
/// session's serial writer queue. `appendVideo` / `appendAudio` are called from
/// the video and audio queues and hop here asynchronously, which is what makes
/// the writer's session-start bookkeeping (`sessionStarted`, `firstPTS`,
/// `lastPTS`) safe without a lock and keeps a slow encode from ever blocking
/// the capture callbacks. `@unchecked Sendable` on the same argument the
/// `TapWriter` / `RenderLevel` types in `AudioFormat.swift` make: a single
/// documented queue owns the state; the counters are read out only through
/// `snapshot()`, which hops onto that queue.
final class MovieWriter: @unchecked Sendable {
    /// Everything one call to `snapshot()` reports. A value, so it can cross
    /// back to whichever queue asked.
    struct Stats: Sendable {
        var videoAppended = 0
        var videoDropped = 0
        var audioAppended = 0
        var audioDropped = 0
        var duration: TimeInterval = 0
        var failure: String?
    }

    private static let log = Logger(subsystem: "dev.kleoth", category: "ScreenRecording")

    private let queue = DispatchQueue(label: "dev.kleoth.screenrecording.writer")
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    /// Called (once) on `queue` the first time an append fails the writer.
    private let onFailure: @Sendable (String) -> Void

    private var sessionStarted = false
    private var finished = false
    private var failureMessage: String?
    private var stats = Stats()
    private var firstPTS: CMTime = .invalid
    private var lastPTS: CMTime = .invalid

    /// The in-flight URL this writer owns (`…​.recording.mp4`).
    let outputURL: URL

    /// - Throws: `ScreenRecorderError.writerSetupFailed` when the file cannot be
    ///   created or the inputs cannot be attached.
    init(
        outputURL: URL,
        pixelSize: CGSize,
        videoBitRate: Int,
        fragmentInterval: TimeInterval?,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        self.outputURL = outputURL
        self.onFailure = onFailure

        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw ScreenRecorderError.writerSetupFailed(error.localizedDescription)
        }

        // A fragmented MP4 whose every completed interval survives a crash,
        // a SIGKILL or a power loss (§5.5); `nil` gives a plain moov-at-front
        // file instead.
        if let fragmentInterval, fragmentInterval > 0 {
            writer.movieFragmentInterval = CMTime(seconds: fragmentInterval, preferredTimescale: 600)
        }
        writer.shouldOptimizeForNetworkUse = true

        videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: VideoFormat.h264Settings(pixelSize: pixelSize, averageBitRate: videoBitRate)
        )
        // The AAC bit rate goes through `AudioFormat.aacSettings` so its
        // encoder clamp (72cca9a) stays in the path — a future mic-only mode on
        // a 16 kHz device must not be able to reproduce the '!dat' failure.
        audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: AudioFormat.aacSettings(
                sampleRate: ScreenRecordingDefaults.audioSampleRate,
                channels: Int(ScreenRecordingDefaults.audioChannels),
                bitRate: ScreenRecordingDefaults.audioBitRate
            )
        )
        // Both must be set BEFORE `startWriting` (AVAssetWriterInput.h:167-174).
        videoInput.expectsMediaDataInRealTime = true
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput) else {
            throw ScreenRecorderError.writerSetupFailed("the H.264 input was rejected")
        }
        writer.add(videoInput)
        guard writer.canAdd(audioInput) else {
            throw ScreenRecorderError.writerSetupFailed("the AAC input was rejected")
        }
        writer.add(audioInput)

        guard writer.startWriting() else {
            let message = writer.error?.localizedDescription ?? "unknown error"
            throw ScreenRecorderError.writerSetupFailed(message)
        }
    }

    /// Appends one video frame. The writer session starts at the FIRST frame
    /// that gets this far, so `startSession` and the first append are one
    /// atomic step on this queue and audio can never open the movie.
    func appendVideo(_ sampleBuffer: CMSampleBuffer, at pts: CMTime) {
        let box = SampleBufferBox(sampleBuffer)
        queue.async { [self] in
            guard !finished, failureMessage == nil else { return }
            if !sessionStarted {
                writer.startSession(atSourceTime: pts)
                sessionStarted = true
                firstPTS = pts
            }
            guard videoInput.isReadyForMoreMediaData else {
                stats.videoDropped += 1
                return
            }
            guard videoInput.append(box.buffer) else {
                noteFailure()
                return
            }
            stats.videoAppended += 1
            if !lastPTS.isValid || pts > lastPTS { lastPTS = pts }
        }
    }

    /// Appends one 20 ms mix block. Blocks stamped before the session start are
    /// discarded (§5.3) — there is nothing for them to be in sync with.
    func appendAudio(_ sampleBuffer: CMSampleBuffer, at pts: CMTime) {
        let box = SampleBufferBox(sampleBuffer)
        queue.async { [self] in
            guard !finished, failureMessage == nil else { return }
            guard sessionStarted, pts >= firstPTS else {
                stats.audioDropped += 1
                return
            }
            guard audioInput.isReadyForMoreMediaData else {
                stats.audioDropped += 1
                return
            }
            guard audioInput.append(box.buffer) else {
                noteFailure()
                return
            }
            stats.audioAppended += 1
        }
    }

    /// A consistent read of the counters, taken on the writer queue.
    func snapshot() -> Stats {
        queue.sync {
            var copy = stats
            copy.failure = failureMessage
            copy.duration = duration
            return copy
        }
    }

    /// `true` once a video frame has opened the session — the audio pump waits
    /// for this before it starts emitting.
    var hasSession: Bool {
        queue.sync { sessionStarted }
    }

    /// Marks both inputs finished and awaits `finishWriting`.
    ///
    /// The completion-handler form, never the deprecated synchronous one
    /// (AVAssetWriter.h:384) — the synchronous call blocks whatever thread it is
    /// on until the file is closed, which on the main actor is the freeze this
    /// project already fixed once for meeting combines.
    ///
    /// - Returns: the final stats.
    /// - Throws: `ScreenRecorderError.writerFailed` when the writer ended in
    ///   `.failed`.
    func finish() async throws -> Stats {
        let alreadyFinished: Bool = queue.sync {
            let was = finished
            finished = true
            return was
        }
        if alreadyFinished { return snapshot() }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                videoInput.markAsFinished()
                audioInput.markAsFinished()
                writer.finishWriting { continuation.resume() }
            }
        }

        let final = snapshot()
        if writer.status == .failed {
            let message = writer.error?.localizedDescription ?? final.failure ?? "unknown error"
            Self.log.error("screen recording writer failed: \(message, privacy: .public)")
            throw ScreenRecorderError.writerFailed(message)
        }
        return final
    }

    /// Best-effort teardown for a path that never reached `finish()` (a start
    /// that threw). Never throws; the caller deletes the file.
    func cancel() {
        queue.sync { [self] in
            guard !finished else { return }
            finished = true
            writer.cancelWriting()
        }
    }

    // MARK: - Internals (writer queue only)

    private var duration: TimeInterval {
        guard firstPTS.isValid, lastPTS.isValid else { return 0 }
        let elapsed = CMTimeSubtract(lastPTS, firstPTS).seconds
        return elapsed.isFinite ? max(0, elapsed) : 0
    }

    /// Carries one `CMSampleBuffer` from a capture queue to the writer queue.
    /// `CMSampleBuffer` is a reference type Swift 6 does not know is safe to
    /// hand over; it is, because exactly one queue touches it at a time — the
    /// producer stops referencing it the moment the box is made. Same argument
    /// as `SendableAudioFileBox` (`AudioFormat.swift:252-263`).
    private final class SampleBufferBox: @unchecked Sendable {
        let buffer: CMSampleBuffer
        init(_ buffer: CMSampleBuffer) { self.buffer = buffer }
    }

    private func noteFailure() {
        let message = writer.error?.localizedDescription ?? "the writer rejected a sample"
        guard failureMessage == nil else { return }
        failureMessage = message
        Self.log.error("screen recording append failed: \(message, privacy: .public)")
        onFailure(message)
    }
}
