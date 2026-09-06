import Foundation
import KleothCore

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
///
/// **T0 STUB** — the surface is final and every entry point throws. T3 builds
/// the real thing.
@MainActor
public final class ScreenRecorder {
    private let configuration: ScreenRecordingConfiguration
    private let stream: AsyncStream<ScreenRecorderEvent>

    public init(configuration: ScreenRecordingConfiguration) {
        self.configuration = configuration
        // Finishes immediately: nothing produces events until T3.
        self.stream = AsyncStream { $0.finish() }
    }

    /// Resolves `SCShareableContent` (under `withTimeout` — it can hang while
    /// the TCC dialog is up), builds the filter + stream configuration (§5.2),
    /// opens the writer, starts capture, and returns after the first `.screen`
    /// sample of any status — or throws `.noFirstFrame` after
    /// `firstFrameTimeout`, deleting the file.
    public func start() async throws {
        _ = configuration
        throw ScreenRecorderError.writerSetupFailed("ScreenRecorder not implemented — T3")
    }

    /// Idempotent. Stops the stream + mic, appends the retained last frame at
    /// the stop time (§5.3), flushes the mix pump, awaits `finishWriting`, and
    /// renames to the final URL. Bounded by `finalizeTimeout`.
    @discardableResult
    public func stop(reason: ScreenRecordingStopReason) async throws -> ScreenRecordingSummary {
        _ = reason
        throw ScreenRecorderError.writerSetupFailed("ScreenRecorder not implemented — T3")
    }

    public var events: AsyncStream<ScreenRecorderEvent> { stream }
}
