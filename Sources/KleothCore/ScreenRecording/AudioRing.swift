import Foundation

/// A single-writer / single-reader float ring addressed by **absolute sample
/// position**, not as a FIFO (design §3.1, §4.2).
///
/// This is the piece that makes the mixer indifferent to the three things that
/// actually happen during a screen recording: a source that stops delivering
/// (ScreenCaptureKit emits no audio while the system is silent on some
/// versions; the mic disappears when a headset is unplugged), a source that
/// delivers late, and a source that attaches mid-session. A write lands where
/// its timestamp says it belongs; positions nobody wrote read back as silence;
/// a buffer whose position has already been consumed is dropped and counted
/// instead of being pasted in at the wrong place.
///
/// Storage is interleaved at `channels`. A mono source is duplicated into both
/// channels on the way in (a Bluetooth HFP mic is 16 kHz **mono**), so the mix
/// bus is stereo end to end.
///
/// Threading: the type is a value with no reference storage, so `Sendable` is
/// free — but it is still a *single-writer, single-reader* structure. Both
/// sources and the pump touch it on one serial queue (`audioQueue`, §4.2);
/// nothing here is safe under concurrent mutation.
public struct AudioRing: Sendable {
    /// Frames the ring can hold before the oldest are overwritten.
    public let capacityFrames: Int
    /// Channels in the ring itself (2 for the mix bus).
    public let channels: Int

    private var storage: [Float]
    private var writeCursorValue: Int64 = 0
    private var readCursorValue: Int64 = 0
    private var droppedValue: Int64 = 0

    public init(capacityFrames: Int, channels: Int) {
        let frames = max(1, capacityFrames)
        let channelCount = max(1, channels)
        self.capacityFrames = frames
        self.channels = channelCount
        self.storage = [Float](repeating: 0, count: frames * channelCount)
    }

    /// One past the last written frame — the position the next contiguous
    /// buffer is expected at.
    public var writeCursor: Int64 { writeCursorValue }

    /// One past the last frame handed to `read` — everything below this has
    /// already been mixed, so a write that lands there is too late to use.
    public var readCursor: Int64 { readCursorValue }

    /// Frames discarded because they arrived after the pump had already mixed
    /// their position.
    public var dropped: Int64 { droppedValue }

    /// Writes `frames` (interleaved at `channels` source channels) at the
    /// absolute sample `position`.
    ///
    /// A position within `tolerance` of ``writeCursor`` — in either direction —
    /// is snapped to the write cursor and appended contiguously. That is what
    /// keeps timestamp jitter (a buffer stamped 0.4 ms early) from punching a
    /// one-sample hole or overlapping the previous buffer, either of which is
    /// an audible click at 48 kHz. A larger jump is honored literally: the gap
    /// it opens is zero-filled so a previous lap of the ring cannot read back
    /// as audio.
    ///
    /// - Returns: the number of frames actually stored (0 when the whole buffer
    ///   was late).
    @discardableResult
    public mutating func write(
        _ frames: UnsafeBufferPointer<Float>,
        channels sourceChannels: Int,
        at position: Int64,
        tolerance: Int
    ) -> Int {
        guard sourceChannels > 0, let source = frames.baseAddress else { return 0 }
        var frameCount = frames.count / sourceChannels
        guard frameCount > 0 else { return 0 }

        var start = position
        let delta = start - writeCursorValue
        if delta != 0, abs(delta) <= Int64(max(0, tolerance)) {
            start = writeCursorValue
        }

        // Anything already mixed is unusable: drop it (counted), keep the tail.
        var sourceOffset = 0
        if start < readCursorValue {
            let behind = readCursorValue - start
            if behind >= Int64(frameCount) {
                droppedValue += Int64(frameCount)
                return 0
            }
            sourceOffset = Int(behind)
            droppedValue += behind
            frameCount -= sourceOffset
            start = readCursorValue
        }

        // A buffer longer than the ring can only leave its tail behind.
        if frameCount > capacityFrames {
            let excess = frameCount - capacityFrames
            sourceOffset += excess
            frameCount -= excess
            start += Int64(excess)
        }

        // Silence whatever the timestamp skipped over, bounded by the ring.
        if start > writeCursorValue {
            let gapStart = max(writeCursorValue, start - Int64(capacityFrames))
            zeroFrames(from: gapStart, count: Int(start - gapStart))
        }

        copyIn(source: source, sourceChannels: sourceChannels, sourceOffset: sourceOffset, count: frameCount, at: start)
        writeCursorValue = max(writeCursorValue, start + Int64(frameCount))
        return frameCount
    }

    /// Reads `count` frames starting at absolute `position` into `out`
    /// (interleaved at ``channels``). Positions nobody wrote — before the
    /// ring's oldest surviving frame, or at/after ``writeCursor`` — come back
    /// as zeros.
    ///
    /// - Returns: how many of the `count` frames were inside the written window
    ///   ("real" audio). The pump turns a run of zero-real mic blocks into a
    ///   ``ScreenRecordingSummary/MicGap``.
    @discardableResult
    public mutating func read(
        into out: UnsafeMutableBufferPointer<Float>,
        count: Int,
        at position: Int64
    ) -> Int {
        guard count > 0, let destination = out.baseAddress else { return 0 }
        let capacity = min(out.count, count * channels)
        guard capacity > 0 else { return 0 }
        destination.update(repeating: 0, count: capacity)

        let oldest = max(0, writeCursorValue - Int64(capacityFrames))
        let from = max(position, oldest)
        let to = min(position + Int64(count), writeCursorValue)
        var real = 0
        if to > from {
            real = Int(to - from)
            copyOut(
                destination: destination,
                destinationCapacity: capacity,
                destinationFrameOffset: Int(from - position),
                count: real,
                at: from
            )
        }
        readCursorValue = max(readCursorValue, position + Int64(count))
        return real
    }

    // MARK: - Internals

    private mutating func zeroFrames(from position: Int64, count: Int) {
        guard count > 0 else { return }
        let channelCount = channels
        let capacity = capacityFrames
        storage.withUnsafeMutableBufferPointer { ring in
            guard let base = ring.baseAddress else { return }
            var remaining = count
            var pos = position
            while remaining > 0 {
                let slot = Int(pos % Int64(capacity))
                let run = min(remaining, capacity - slot)
                (base + slot * channelCount).update(repeating: 0, count: run * channelCount)
                remaining -= run
                pos += Int64(run)
            }
        }
    }

    private mutating func copyIn(
        source: UnsafePointer<Float>,
        sourceChannels: Int,
        sourceOffset: Int,
        count: Int,
        at position: Int64
    ) {
        let channelCount = channels
        let capacity = capacityFrames
        storage.withUnsafeMutableBufferPointer { ring in
            guard let base = ring.baseAddress else { return }
            var remaining = count
            var pos = position
            var read = sourceOffset
            while remaining > 0 {
                let slot = Int(pos % Int64(capacity))
                let run = min(remaining, capacity - slot)
                var destination = base + slot * channelCount
                var origin = source + read * sourceChannels
                if sourceChannels == channelCount {
                    destination.update(from: origin, count: run * channelCount)
                } else if sourceChannels == 1 {
                    // Mono in, stereo (or more) ring: duplicate across channels.
                    for _ in 0..<run {
                        let sample = origin.pointee
                        for channel in 0..<channelCount { destination[channel] = sample }
                        destination += channelCount
                        origin += 1
                    }
                } else {
                    // More source channels than the ring: keep the first N.
                    let keep = min(sourceChannels, channelCount)
                    for _ in 0..<run {
                        for channel in 0..<channelCount {
                            destination[channel] = channel < keep ? origin[channel] : 0
                        }
                        destination += channelCount
                        origin += sourceChannels
                    }
                }
                remaining -= run
                pos += Int64(run)
                read += run
            }
        }
    }

    private func copyOut(
        destination: UnsafeMutablePointer<Float>,
        destinationCapacity: Int,
        destinationFrameOffset: Int,
        count: Int,
        at position: Int64
    ) {
        let channelCount = channels
        let capacity = capacityFrames
        storage.withUnsafeBufferPointer { ring in
            guard let base = ring.baseAddress else { return }
            var remaining = count
            var pos = position
            var written = destinationFrameOffset
            while remaining > 0 {
                let slot = Int(pos % Int64(capacity))
                let run = min(remaining, capacity - slot)
                let outOffset = written * channelCount
                let samples = min(run * channelCount, max(0, destinationCapacity - outOffset))
                if samples > 0 {
                    (destination + outOffset).update(from: base + slot * channelCount, count: samples)
                }
                remaining -= run
                pos += Int64(run)
                written += run
            }
        }
    }
}
