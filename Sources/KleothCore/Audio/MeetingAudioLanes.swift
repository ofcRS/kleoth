import Foundation

/// A meeting's two capture lanes as their files report them (`mic.m4a`,
/// `system.m4a`), and what follows for the combined `meeting.m4a` built from
/// them: whether it is the old combine's wrong-rate file, how long it must
/// last, and how long the combine up to 0.5.7 made it.
///
/// The lanes run at their own rates: the system tap at the output's rate
/// (48 kHz in practice), the microphone at whatever the device runs (16 kHz
/// for a Bluetooth headset in HFP, 44.1 kHz for a MacBook's array). The old
/// combine wrote both lanes' frames at the MICROPHONE's rate without
/// resampling, so whenever the two rates differed the other side's channel
/// played at the wrong speed — three times too slow beside a 16 kHz
/// microphone, where the file also lasted three times the meeting. The lane
/// files themselves were always right. Pure: the caller probes the files.
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

    /// The rate a correct combined file runs at: the higher lane's (the
    /// combine resamples the other lane up to it). nil without a lane.
    public var highestSampleRate: Double? {
        [mic?.sampleRate, system?.sampleRate].compactMap { $0 }.max()
    }

    /// How long a correct `meeting.m4a` lasts: the longer lane (the shorter one
    /// is padded with silence). nil without a lane.
    public var expectedSeconds: Double? {
        [mic?.seconds, system?.seconds].compactMap { $0 }.max()
    }

    /// How long the combine up to 0.5.7 made `meeting.m4a`: the longer lane's
    /// FRAME count at the microphone's rate (channel 0's, whenever it held
    /// audio), else the system lane as it is. Equal to ``expectedSeconds`` when
    /// both lanes share a rate, and also whenever the microphone lane has at
    /// least as many frames as the other — the old file then lasted the right
    /// time with the other side still at the wrong speed.
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

    /// Whether a readable `meeting.m4a` at `combinedSampleRate` is the old
    /// combine's file and must be rebuilt from the lanes. `resampled` says the
    /// file carries the mark every combine since the fix leaves on it
    /// (`MeetingAudioRepair`): such a file is never rebuilt.
    ///
    /// Decided by RATE, not length: the old combine wrote at the microphone's
    /// rate, the new one at the higher lane's. A file below the higher lane's
    /// rate is the old one whatever its length (with a microphone lane of at
    /// least as many frames as the other, the length came out right and the
    /// other side was still slowed). The one case rate cannot tell — a
    /// microphone ABOVE the system lane's rate, where both combines write the
    /// microphone's — is told by the mark: an unmarked file there is the old
    /// one. A file that lost its mark in a copy is only rebuilt once more.
    public func combinedNeedsRebuild(combinedSampleRate: Double, resampled: Bool) -> Bool {
        guard !resampled, let highest = highestSampleRate else { return false }
        if combinedSampleRate < highest { return true }
        if let mic, let system, mic.sampleRate > system.sampleRate { return true }
        return false
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

/// What the launch repair remembers per output folder, so it scans the old
/// meetings once instead of on every launch (`RecordingController`
/// `repairCombinedAudioAtLaunch`). Pure; the app keeps it in UserDefaults.
public struct MeetingAudioRepairState: Codable, Sendable, Equatable {
    /// Bump to make every Mac scan its meetings once more.
    public static let currentPass = 1

    /// The last full pass that finished; nil before the first.
    public var completedPass: Int?
    /// Meeting folder names to look at again next launch: busy (recording or
    /// processing), interrupted, files not downloaded from a cloud folder, or
    /// a stored length not yet corrected.
    public var pending: [String]
    /// Meeting folder names whose rebuild failed: never retried by the app
    /// (`recombine` still repairs them).
    public var failed: [String]

    public init(completedPass: Int? = nil, pending: [String] = [], failed: [String] = []) {
        self.completedPass = completedPass
        self.pending = pending
        self.failed = failed
    }

    /// The folders this launch looks at, out of the meeting folders `all`:
    /// every one until a full pass has finished, then only the pending ones
    /// (a meeting recorded since is combined right and never needs it).
    /// Failed folders are left out either way.
    public func foldersToCheck(all: [String]) -> [String] {
        let skipped = Set(failed)
        guard completedPass == Self.currentPass else { return all.filter { !skipped.contains($0) } }
        let wanted = Set(pending)
        return all.filter { wanted.contains($0) && !skipped.contains($0) }
    }
}
