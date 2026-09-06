import AVFoundation
import CoreMedia
import Foundation
import KleothCore
import ScreenCaptureKit

/// Decides which ScreenCaptureKit frames reach the writer, and keeps the last
/// one so a frozen screen still produces a full-length movie (design §5.3).
///
/// Three rules, each earned:
/// 1. **Only `SCFrameStatus.complete`.** The other statuses (`.idle`, `.blank`,
///    `.suspended`, `.started`, `.stopped`) carry no new pixels; Apple's own
///    sample drops them.
/// 2. **Strictly increasing PTS.** A duplicate or out-of-order timestamp makes
///    `AVAssetWriterInput.append` fail the whole writer, which would end the
///    recording — dropping the frame instead costs one frame.
/// 3. **Re-append the last frame at stop.** ScreenCaptureKit emits a frame only
///    when the screen *changes*, so a static tail would otherwise end the video
///    track at the last change while audio kept going. A retimed copy of the
///    retained frame at the stop time makes the two tracks the same length.
///
/// **Threading:** every stored property is touched ONLY on the session's video
/// queue, which is the queue ScreenCaptureKit was given for the `.screen`
/// output — plus `appendFinalFrame(at:)`, which the recorder dispatches onto
/// that same queue. `@unchecked Sendable` on that single-queue argument.
final class VideoFrameGate: @unchecked Sendable {
    private let writer: MovieWriter
    /// Fired once, with the host time of the FIRST `.screen` sample of ANY
    /// status: the stale-TCC-grant detector's all-clear (§5.3, error matrix #3).
    private let onFirstSample: @Sendable (UInt64) -> Void

    private var sawFirstSample = false
    private var lastAppendedPTS: CMTime = .invalid
    private var lastFrame: CMSampleBuffer?
    /// Frames rejected by the gate itself (status or PTS). Frames the writer
    /// could not take are counted separately, in `MovieWriter.Stats`.
    private var gateDropped = 0

    init(writer: MovieWriter, onFirstSample: @escaping @Sendable (UInt64) -> Void) {
        self.writer = writer
        self.onFirstSample = onFirstSample
    }

    /// Video-queue only.
    var droppedCount: Int { gateDropped }

    /// The PTS of the newest frame handed to the writer, or `.invalid`.
    /// Video-queue only.
    var lastPresentationTime: CMTime { lastAppendedPTS }

    /// One `.screen` sample from `SCStreamOutput`. Video-queue only.
    func handle(_ sampleBuffer: CMSampleBuffer) {
        if !sawFirstSample {
            sawFirstSample = true
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let hostTime = pts.isValid ? CMClockConvertHostTimeToSystemUnits(pts) : mach_absolute_time()
            onFirstSample(hostTime)
        }

        guard status(of: sampleBuffer) == .complete else {
            gateDropped += 1
            return
        }
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
            gateDropped += 1
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.isNumeric else {
            gateDropped += 1
            return
        }
        guard !lastAppendedPTS.isValid || pts > lastAppendedPTS else {
            gateDropped += 1
            return
        }

        lastAppendedPTS = pts
        lastFrame = sampleBuffer
        writer.appendVideo(sampleBuffer, at: pts)
    }

    /// Retimes the retained last frame to `pts` and appends it, so the video
    /// track reaches the stop time even if nothing on screen moved. Obeys the
    /// same monotonic guard. Video-queue only.
    ///
    /// - Returns: `true` when a frame was appended.
    @discardableResult
    func appendFinalFrame(at pts: CMTime) -> Bool {
        guard let lastFrame, pts.isValid, pts.isNumeric else { return false }
        guard !lastAppendedPTS.isValid || pts > lastAppendedPTS else { return false }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: lastFrame,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        guard status == noErr, let copy else { return false }

        lastAppendedPTS = pts
        writer.appendVideo(copy, at: pts)
        return true
    }

    /// Releases the retained frame — ScreenCaptureKit's `queueDepth` surface
    /// pool is small, so the last one must not outlive the session.
    /// Video-queue only.
    func releaseRetainedFrame() {
        lastFrame = nil
    }

    // MARK: - Internals

    private func status(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int
        else { return nil }
        return SCFrameStatus(rawValue: raw)
    }
}
