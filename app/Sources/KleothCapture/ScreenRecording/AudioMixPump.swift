import AVFoundation
import CoreMedia
import Foundation
import KleothCore

/// The two position-addressed rings plus the session origin they are addressed
/// against (design §4.2).
///
/// **Threading:** every method here is **audio-queue only**. The microphone tap
/// runs on `AVAudioEngine`'s render thread and the ScreenCaptureKit `.screen`
/// output on the video queue, so both hop onto the audio queue before they
/// touch this. That single serial queue is the whole synchronization story —
/// hence `@unchecked Sendable`, the `TapWriter` argument.
final class AudioRingBox: @unchecked Sendable {
    private var micRing: AudioRing
    private var systemRing: AudioRing
    private let tolerance: Int

    /// Host time of the writer's session start (the first appended video
    /// frame). `nil` until a frame has opened the movie — audio arriving before
    /// that has nothing to be in sync with and is dropped.
    private(set) var origin: UInt64?
    /// The same instant as a `CMTime`, so emitted blocks can be stamped
    /// `originPTS + position/48000` and land exactly on the video timeline.
    private(set) var originPTS: CMTime = .invalid

    init(capacityFrames: Int, channels: Int, tolerance: Int) {
        micRing = AudioRing(capacityFrames: capacityFrames, channels: channels)
        systemRing = AudioRing(capacityFrames: capacityFrames, channels: channels)
        self.tolerance = tolerance
    }

    func setOrigin(hostTime: UInt64, pts: CMTime) {
        guard origin == nil else { return }
        origin = hostTime
        originPTS = pts
    }

    func writeMic(_ frames: UnsafeBufferPointer<Float>, channels: Int, at position: Int64) {
        micRing.write(frames, channels: channels, at: position, tolerance: tolerance)
    }

    func writeSystem(_ frames: UnsafeBufferPointer<Float>, channels: Int, at position: Int64) {
        systemRing.write(frames, channels: channels, at: position, tolerance: tolerance)
    }

    func readMic(into out: UnsafeMutableBufferPointer<Float>, count: Int, at position: Int64) -> Int {
        micRing.read(into: out, count: count, at: position)
    }

    func readSystem(into out: UnsafeMutableBufferPointer<Float>, count: Int, at position: Int64) -> Int {
        systemRing.read(into: out, count: count, at: position)
    }

    var micDropped: Int64 { micRing.dropped }
    var systemDropped: Int64 { systemRing.dropped }
}

/// Pulls one 20 ms block out of both rings on a timer, sums them, and hands the
/// result to the writer as a single interleaved Float32 stereo LPCM sample
/// buffer (design §4.3).
///
/// **Pull, not push.** Either source can stop delivering — ScreenCaptureKit
/// emits nothing while the system is silent on some versions, the mic vanishes
/// when a headset is unplugged — and the recording still needs ONE continuous,
/// in-sync audio track. A pump makes silence explicit and cheap: it reads
/// whatever position it is due, and a lane with nothing written there simply
/// reads as zeros. The 250 ms it stays behind "now" is what lets a late buffer
/// still land in the right place; it costs nothing in sync, because every PTS
/// is a real host time, and nothing to the writer, whose real-time inputs
/// interleave by PTS.
///
/// It never blocks: a block the writer is not ready for is counted and dropped
/// rather than retried, so the timer cannot back up behind the encoder.
///
/// **Threading:** the timer runs on the session's audio queue and every stored
/// property is audio-queue only. `@unchecked Sendable` on that argument.
final class AudioMixPump: @unchecked Sendable {
    struct Stats: Sendable {
        var blocksEmitted = 0
        var blocksDropped = 0
        var micCaptured = false
        var micGaps: [ScreenRecordingSummary.MicGap] = []
        /// Mic frames that were really written vs. frames the mixer asked for —
        /// the probe's "mic real-frames %" and the honest answer to "did the
        /// microphone actually work".
        var micRealFrames: Int64 = 0
        var micTotalFrames: Int64 = 0
    }

    private let queue: DispatchQueue
    private let rings: AudioRingBox
    private let writer: MovieWriter
    private let clock: HostClockMath
    private let sampleRate: Double
    private let blockFrames: Int
    private let channels: Int
    private let latencyFrames: Int64
    private let onGapBegan: @Sendable (TimeInterval) -> Void
    private let onGapEnded: @Sendable (TimeInterval) -> Void

    private var timer: DispatchSourceTimer?
    private var formatDescription: CMAudioFormatDescription?
    private var nextPosition: Int64 = 0
    private var micScratch: [Float]
    private var systemScratch: [Float]
    private var mixScratch: [Float]
    private var stats = Stats()
    /// Sample position where the current run of silent mic blocks began.
    private var gapStart: Int64?
    /// Whether `onGapBegan` has already fired for the run in `gapStart`.
    private var gapReported = false

    init(
        queue: DispatchQueue,
        rings: AudioRingBox,
        writer: MovieWriter,
        clock: HostClockMath,
        sampleRate: Double,
        blockFrames: Int,
        channels: Int,
        latency: TimeInterval,
        onGapBegan: @escaping @Sendable (TimeInterval) -> Void,
        onGapEnded: @escaping @Sendable (TimeInterval) -> Void
    ) {
        self.queue = queue
        self.rings = rings
        self.writer = writer
        self.clock = clock
        self.sampleRate = sampleRate
        self.blockFrames = blockFrames
        self.channels = channels
        self.latencyFrames = Int64((latency * sampleRate).rounded())
        self.onGapBegan = onGapBegan
        self.onGapEnded = onGapEnded
        let samples = blockFrames * channels
        micScratch = [Float](repeating: 0, count: samples)
        systemScratch = [Float](repeating: 0, count: samples)
        mixScratch = [Float](repeating: 0, count: samples)
    }

    /// Starts the 20 ms timer. Safe to call once; audio-queue affinity is
    /// established by the timer's own queue.
    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let interval = Double(blockFrames) / sampleRate
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(
                deadline: .now() + interval,
                repeating: interval,
                leeway: .milliseconds(5)
            )
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }
    }

    /// Stops the timer, emits every block that is due up to `stopPosition`
    /// (so the audio track reaches the same instant the video's final frame
    /// does), and returns the session's audio stats.
    func stop(at stopPosition: Int64) async -> Stats {
        await withCheckedContinuation { (continuation: CheckedContinuation<Stats, Never>) in
            queue.async { [self] in
                timer?.cancel()
                timer = nil
                // The tail is allowed to be a partial block so the audio track
                // reaches the same instant the video's retimed final frame
                // does, instead of stopping up to 20 ms short of it.
                emit(upTo: stopPosition, budget: 2_000, allowPartialTail: true)
                if let start = gapStart {
                    closeGap(startingAt: start, endingAt: nextPosition)
                    gapStart = nil
                }
                continuation.resume(returning: stats)
            }
        }
    }

    /// A consistent read of the counters, taken on the audio queue.
    func snapshot() -> Stats {
        queue.sync { stats }
    }

    // MARK: - Internals (audio queue only)

    private func tick() {
        guard let origin = rings.origin else { return }
        let now = clock.samplePosition(hostTime: mach_absolute_time(), origin: origin, sampleRate: sampleRate)
        emit(upTo: now - latencyFrames, budget: 100)
    }

    /// Emits every whole block that ends at or before `target`.
    ///
    /// `budget` bounds one call so a stalled queue cannot turn into an
    /// unbounded burst; when the backlog is bigger than the rings can hold, the
    /// position jumps forward instead — those samples are gone either way, and
    /// a jump keeps every later block's PTS honest.
    private func emit(upTo target: Int64, budget: Int, allowPartialTail: Bool = false) {
        guard rings.origin != nil, blockFrames > 0 else { return }

        let backlog = target - nextPosition
        let maximum = Int64(budget * blockFrames)
        if backlog > maximum {
            let skipped = backlog - maximum
            let blocks = skipped / Int64(blockFrames)
            nextPosition += blocks * Int64(blockFrames)
            stats.blocksDropped += Int(blocks)
        }

        while nextPosition + Int64(blockFrames) <= target {
            emitBlock(frames: blockFrames)
        }
        if allowPartialTail {
            let remainder = Int(target - nextPosition)
            if remainder > 0 { emitBlock(frames: remainder) }
        }
    }

    /// `frames` is `blockFrames` for every regular block and the short
    /// remainder for the one optional tail block.
    private func emitBlock(frames: Int) {
        let position = nextPosition
        let samples = frames * channels
        let micReal = micScratch.withUnsafeMutableBufferPointer {
            rings.readMic(into: $0, count: frames, at: position)
        }
        _ = systemScratch.withUnsafeMutableBufferPointer {
            rings.readSystem(into: $0, count: frames, at: position)
        }
        micScratch.withUnsafeBufferPointer { mic in
            systemScratch.withUnsafeBufferPointer { system in
                mixScratch.withUnsafeMutableBufferPointer { out in
                    MixMath.sumAndLimit(
                        UnsafeBufferPointer(rebasing: mic.prefix(samples)),
                        UnsafeBufferPointer(rebasing: system.prefix(samples)),
                        into: UnsafeMutableBufferPointer(rebasing: out.prefix(samples))
                    )
                }
            }
        }

        if let buffer = makeSampleBuffer(at: position, frames: frames) {
            writer.appendAudio(buffer, at: CMSampleBufferGetPresentationTimeStamp(buffer))
            stats.blocksEmitted += 1
        } else {
            stats.blocksDropped += 1
        }

        stats.micRealFrames += Int64(micReal)
        stats.micTotalFrames += Int64(frames)
        track(micReal: micReal, frames: frames, at: position)
        nextPosition = position + Int64(frames)
    }

    private func track(micReal: Int, frames: Int, at position: Int64) {
        if micReal > 0 {
            stats.micCaptured = true
            if let start = gapStart {
                closeGap(startingAt: start, endingAt: position)
                gapStart = nil
            }
            return
        }
        // A microphone that never produced a sample is "no mic", not a gap.
        guard stats.micCaptured else { return }
        if gapStart == nil {
            gapStart = position
            gapReported = false
        } else if !gapReported, let start = gapStart,
                  seconds(from: start, to: position + Int64(frames)) >= ScreenRecordingDefaults.micGapReportThreshold {
            gapReported = true
            onGapBegan(seconds(at: start))
        }
    }

    private func closeGap(startingAt start: Int64, endingAt end: Int64) {
        let duration = seconds(from: start, to: end)
        guard duration >= ScreenRecordingDefaults.micGapReportThreshold else {
            gapReported = false
            return
        }
        stats.micGaps.append(.init(at: seconds(at: start), duration: duration))
        if gapReported { onGapEnded(seconds(at: end)) }
        gapReported = false
    }

    private func seconds(at position: Int64) -> TimeInterval {
        Double(position) / sampleRate
    }

    private func seconds(from start: Int64, to end: Int64) -> TimeInterval {
        max(0, Double(end - start) / sampleRate)
    }

    /// One block as an interleaved Float32 stereo LPCM `CMSampleBuffer`.
    /// `CMSampleBufferSetDataBufferFromAudioBufferList` copies the samples (the
    /// 16-byte-alignment flag forces a fresh, aligned block buffer), so the
    /// scratch is free to be reused on the next tick.
    private func makeSampleBuffer(at position: Int64, frames: Int) -> CMSampleBuffer? {
        guard frames > 0, let format = audioFormatDescription() else { return nil }
        let timescale = CMTimeScale(sampleRate.rounded())
        let offset = CMTime(value: position, timescale: timescale)
        let pts = CMTimeAdd(rings.originPTS, offset)
        guard pts.isValid, pts.isNumeric else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: timescale),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var buffer: CMSampleBuffer?
        let created = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: CMItemCount(frames),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &buffer
        )
        guard created == noErr, let buffer else { return nil }

        var attached: OSStatus = noErr
        mixScratch.withUnsafeMutableBufferPointer { samples in
            guard let base = samples.baseAddress else {
                attached = -1
                return
            }
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(frames * channels * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(base)
                )
            )
            attached = CMSampleBufferSetDataBufferFromAudioBufferList(
                buffer,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                bufferList: &list
            )
        }
        guard attached == noErr else { return nil }
        return buffer
    }

    private func audioFormatDescription() -> CMAudioFormatDescription? {
        if let formatDescription { return formatDescription }
        let bytesPerFrame = UInt32(channels * MemoryLayout<Float>.size)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        guard status == noErr else { return nil }
        formatDescription = description
        return description
    }
}
