import Foundation

/// A meeting's two capture lanes as their files report them (`mic.m4a`,
/// `system.m4a`), and what follows for the combined `meeting.m4a` built from
/// them: how long it must last, and how long the combine up to 0.5.7 made it.
///
/// The lanes run at their own rates: the system tap at 48 kHz, the microphone
/// at whatever the device runs (16 kHz for a Bluetooth headset in HFP, 44.1 kHz
/// for a MacBook's array). The old combine wrote both lanes' frames at the
/// MICROPHONE's rate without resampling, so with a 16 kHz microphone the other
/// side's channel played three times too slow and the file lasted three times
/// the meeting (×1.088 with 44.1 kHz). The lane files themselves were always
/// right. Pure: the caller probes the files.
public struct MeetingAudioLanes: Sendable, Equatable {
    /// One lane file that holds audio: its length in frames at its own rate.
    public struct Lane: Sendable, Equatable {
        public var frames: Int64
        public var sampleRate: Double

        public init(frames: Int64, sampleRate: Double) {
            self.frames = frames
            self.sampleRate = sampleRate
        }

        public var seconds: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }
    }

    /// nil when the file is missing or holds no audio (a header-only `mic.m4a`).
    public var mic: Lane?
    public var system: Lane?

    public init(mic: Lane?, system: Lane?) {
        self.mic = mic
        self.system = system
    }

    /// How long a correct `meeting.m4a` lasts: the longer lane (the shorter one
    /// is padded with silence). nil without a lane.
    public var expectedSeconds: Double? {
        switch (mic, system) {
        case (nil, nil): return nil
        case let (mic?, nil): return mic.seconds
        case let (nil, system?): return system.seconds
        case let (mic?, system?): return max(mic.seconds, system.seconds)
        }
    }

    /// How long the combine up to 0.5.7 made `meeting.m4a`: the longer lane's
    /// FRAME count at the microphone's rate (channel 0's, whenever it held
    /// audio), else the system lane as it is. Equal to ``expectedSeconds`` when
    /// both lanes share a rate — those files were right.
    public var preFixSeconds: Double? {
        switch (mic, system) {
        case (nil, nil): return nil
        case let (mic?, nil): return mic.seconds
        case let (nil, system?): return system.seconds
        case let (mic?, system?):
            guard mic.sampleRate > 0 else { return nil }
            return Double(max(mic.frames, system.frames)) / mic.sampleRate
        }
    }

    /// Two durations of one meeting disagree: by more than 1 % AND more than a
    /// quarter second. The second floor keeps AAC packet rounding (64 ms at
    /// 16 kHz) on a clip of a few seconds from counting.
    public static func differ(_ a: Double, _ b: Double) -> Bool {
        let gap = abs(a - b)
        return gap > 0.25 && gap > 0.01 * max(abs(a), abs(b))
    }

    /// Whether a `meeting.m4a` lasting `combinedSeconds` is the old combine's
    /// wrong-rate file and must be rebuilt from the lanes. Deliberately narrow:
    /// it must be off from the lanes AND match what the old combine made, so a
    /// combined file that disagrees for any other reason is never touched.
    public func combinedNeedsRebuild(combinedSeconds: Double) -> Bool {
        guard let expected = expectedSeconds, let preFix = preFixSeconds else { return false }
        return Self.differ(combinedSeconds, expected) && !Self.differ(combinedSeconds, preFix)
    }

    /// The same cost with the duration the old combine put into it corrected
    /// to the meeting's real one, or nil when there is nothing to correct.
    ///
    /// `meta.json`'s `cost.audio_duration_secs` (and an archived variant's) is
    /// probed from `meeting.m4a` when a transcript is saved, so an affected
    /// meeting stores the stretched length; a cloud transcript's
    /// `transcription_cost` was priced on it too (Scribe itself billed the
    /// correctly resampled mono mix). Only a stored value that matches the old
    /// combine's length is changed, so this is safe to run again and again.
    /// The cost is scaled by the same factor, whatever rate priced it.
    public func corrected(_ cost: CostBreakdown) -> CostBreakdown? {
        guard let stored = cost.audioDurationSecs, stored > 0,
              let expected = expectedSeconds, let preFix = preFixSeconds,
              Self.differ(stored, expected), !Self.differ(stored, preFix) else { return nil }
        var fixed = cost
        fixed.audioDurationSecs = expected
        fixed.transcriptionUSD = cost.transcriptionUSD * expected / stored
        return fixed
    }
}
