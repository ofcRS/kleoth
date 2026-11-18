import AVFoundation
import Foundation
import Testing
@testable import KleothCapture

/// The two capture lanes of a meeting run at their own rates: `system.m4a` at
/// the process tap's 48 kHz, `mic.m4a` at the microphone's (16 kHz for a
/// Bluetooth headset in HFP, 44.1 kHz for a MacBook's array). The combine used
/// to copy both lanes frame for frame at the MICROPHONE's rate, so the other
/// side's channel played three times too slow and `meeting.m4a` lasted three
/// times the meeting. These build both lanes on synthetic tones and read the
/// combined file back.
@Suite struct CombineSampleRateTests {
    /// The microphone's tone and the other side's: different, so a check can
    /// tell the channels apart.
    private static let micTone = 300.0
    private static let systemTone = 440.0

    private func scratchDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-combine-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes `seconds` of a sine at `frequency` on every channel, as a capture
    /// lane would: an AAC file at `sampleRate` (`AudioFormat.openAACFile`).
    private func writeTone(
        _ url: URL, sampleRate: Double, channels: Int, seconds: Double, frequency: Double
    ) throws {
        let format = try #require(AudioFormat.pcmFloat32(sampleRate: sampleRate, channels: channels))
        let total = Int((seconds * sampleRate).rounded())
        let chunk = 4096
        // The file is finalized when its last reference goes.
        do {
            let file = try AudioFormat.openAACFile(at: url, sampleRate: sampleRate, channels: channels)
            var written = 0
            while written < total {
                let count = min(chunk, total - written)
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
                buffer.frameLength = AVAudioFrameCount(count)
                let planes = try #require(buffer.floatChannelData)
                for frame in 0..<count {
                    let t = Double(written + frame) / sampleRate
                    let sample = Float(0.5 * sin(2 * .pi * frequency * t))
                    for channel in 0..<channels { planes[channel][frame] = sample }
                }
                try file.write(from: buffer)
                written += count
            }
        }
    }

    private func seconds(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// One channel of a file, whole, with its rate.
    private func channel(_ index: Int, of url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        let planes = try #require(buffer.floatChannelData)
        let samples = Array(UnsafeBufferPointer(start: planes[index], count: Int(buffer.frameLength)))
        return (samples, file.processingFormat.sampleRate)
    }

    /// The tone's frequency from its rising zero crossings between `from` and
    /// `to` seconds, each crossing placed between its two samples.
    private func frequency(_ samples: [Float], sampleRate: Double, from: Double, to: Double) -> Double {
        let lower = max(1, Int(from * sampleRate))
        let upper = min(samples.count, Int(to * sampleRate))
        var crossings: [Double] = []
        for index in lower..<upper where samples[index - 1] < 0 && samples[index] >= 0 {
            let a = Double(samples[index - 1]), b = Double(samples[index])
            crossings.append(Double(index - 1) + (-a / (b - a)))
        }
        guard crossings.count > 2, let first = crossings.first, let last = crossings.last, last > first else { return 0 }
        return Double(crossings.count - 1) / ((last - first) / sampleRate)
    }

    /// A combine of two lanes at their own rates: the file lasts as long as the
    /// longer lane, and each channel still carries its own tone at its pitch.
    @Test(arguments: [
        // A Bluetooth headset (HFP) beside the 48 kHz tap; the other side talks longer.
        (16_000.0, 4.0, 5.0),
        // A MacBook's array, the other side longer, then the microphone.
        (44_100.0, 4.0, 5.0),
        (44_100.0, 5.0, 4.0),
    ])
    func combineKeepsBothLanesInTime(micRate: Double, micSeconds: Double, systemSeconds: Double) throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = dir.appendingPathComponent("mic.m4a")
        let system = dir.appendingPathComponent("system.m4a")
        let combined = dir.appendingPathComponent("meeting.m4a")
        try writeTone(mic, sampleRate: micRate, channels: 1, seconds: micSeconds, frequency: Self.micTone)
        try writeTone(system, sampleRate: 48_000, channels: 2, seconds: systemSeconds, frequency: Self.systemTone)

        try Recorder.combineChannels(micURL: mic, systemURL: system, outputURL: combined)

        let expected = max(try seconds(of: mic), try seconds(of: system))
        let actual = try seconds(of: combined)
        // Measured equal; 5 ms is a quarter of one AAC packet at 48 kHz.
        #expect(abs(actual - expected) < 0.005, "combined \(actual) s, longer lane \(expected) s")
        // The common rate is the higher one: the other side is never downsampled.
        #expect(try AVAudioFile(forReading: combined).processingFormat.sampleRate == 48_000)

        let other = try channel(1, of: combined)
        let shorter = min(micSeconds, systemSeconds)
        let heard = frequency(other.samples, sampleRate: other.sampleRate, from: 0.5, to: min(systemSeconds, 3.5))
        #expect(abs(heard - Self.systemTone) < Self.systemTone * 0.001, "channel 1 at \(heard) Hz")

        let you = try channel(0, of: combined)
        let spoken = frequency(you.samples, sampleRate: you.sampleRate, from: 0.5, to: min(micSeconds, 3.5))
        #expect(abs(spoken - Self.micTone) < Self.micTone * 0.001, "channel 0 at \(spoken) Hz")

        // Both lanes start together: the two tones share the file's first
        // seconds, and past the shorter lane only the longer one sounds.
        let tail = shorter + 0.3
        let tailEnd = max(micSeconds, systemSeconds) - 0.2
        let quiet = micSeconds < systemSeconds ? you : other
        let lo = Int(tail * quiet.sampleRate), hi = Int(tailEnd * quiet.sampleRate)
        let tailPeak = quiet.samples[lo..<min(hi, quiet.samples.count)].map(abs).max() ?? 0
        #expect(tailPeak < 0.001, "the shorter lane is silent past its end (peak \(tailPeak))")
    }

    /// Both lanes at the same rate (the common 48 kHz case): the file keeps it.
    @Test func sameRateLanesKeepTheirRate() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = dir.appendingPathComponent("mic.m4a")
        let system = dir.appendingPathComponent("system.m4a")
        let combined = dir.appendingPathComponent("meeting.m4a")
        try writeTone(mic, sampleRate: 48_000, channels: 1, seconds: 2.0, frequency: Self.micTone)
        try writeTone(system, sampleRate: 48_000, channels: 2, seconds: 3.0, frequency: Self.systemTone)

        try Recorder.combineChannels(micURL: mic, systemURL: system, outputURL: combined)

        let file = try AVAudioFile(forReading: combined)
        #expect(file.processingFormat.sampleRate == 48_000)
        #expect(file.processingFormat.channelCount == 2)
        #expect(abs(try seconds(of: combined) - (try seconds(of: system))) < 0.005)
        let other = try channel(1, of: combined)
        let heard = frequency(other.samples, sampleRate: other.sampleRate, from: 0.5, to: 2.5)
        #expect(abs(heard - Self.systemTone) < Self.systemTone * 0.001, "channel 1 at \(heard) Hz")
        // Every combined file says it was resampled (`MeetingAudioRepair`).
        #expect(MeetingAudioRepair.isMarkedResampled(combined))
    }

    /// A lane of silence with one burst at `at` seconds.
    private func writeBurst(_ url: URL, sampleRate: Double, channels: Int, seconds: Double, at onset: Double) throws {
        let format = try #require(AudioFormat.pcmFloat32(sampleRate: sampleRate, channels: channels))
        let total = Int(seconds * sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)))
        buffer.frameLength = AVAudioFrameCount(total)
        let planes = try #require(buffer.floatChannelData)
        let start = Int(onset * sampleRate), length = Int(0.2 * sampleRate)
        for frame in 0..<total {
            let inBurst = frame >= start && frame < start + length
            let sample = inBurst ? Float(0.5 * sin(2 * .pi * 1000 * Double(frame - start) / sampleRate)) : 0
            for channel in 0..<channels { planes[channel][frame] = sample }
        }
        do {
            let file = try AudioFormat.openAACFile(at: url, sampleRate: sampleRate, channels: channels)
            try file.write(from: buffer)
        }
    }

    /// When a channel first reaches half its loudest sample, in seconds.
    private func onset(_ samples: [Float], sampleRate: Double) -> Double {
        let peak = samples.map(abs).max() ?? 0
        let index = samples.firstIndex { abs($0) >= peak / 2 } ?? 0
        return Double(index) / sampleRate
    }

    /// The two lanes start together, so a constant offset between what they
    /// carry (the other side speaks half a second after the microphone) stays
    /// exactly that: the resampler adds no delay of its own.
    @Test func aConstantOffsetBetweenTheLanesIsKept() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = dir.appendingPathComponent("mic.m4a")
        let system = dir.appendingPathComponent("system.m4a")
        let combined = dir.appendingPathComponent("meeting.m4a")
        try writeBurst(mic, sampleRate: 16_000, channels: 1, seconds: 3, at: 1.0)
        try writeBurst(system, sampleRate: 48_000, channels: 2, seconds: 3, at: 1.5)

        try Recorder.combineChannels(micURL: mic, systemURL: system, outputURL: combined)

        let micLane = try channel(0, of: mic), systemLane = try channel(0, of: system)
        let you = try channel(0, of: combined), other = try channel(1, of: combined)
        let micOnset = onset(micLane.samples, sampleRate: micLane.sampleRate)
        let systemOnset = onset(systemLane.samples, sampleRate: systemLane.sampleRate)
        // Within 1 ms of where each lane has it.
        #expect(abs(onset(you.samples, sampleRate: you.sampleRate) - micOnset) < 0.001)
        #expect(abs(onset(other.samples, sampleRate: other.sampleRate) - systemOnset) < 0.001)
        #expect(abs((systemOnset - micOnset) - 0.5) < 0.002)
    }

    /// A quiet lane with loud bursts gets a big gain: its ±0.97 ceiling holds
    /// at the OUTPUT rate. Clipped first and resampled after, it overshot.
    @Test func theCeilingHoldsAfterResampling() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = dir.appendingPathComponent("mic.m4a")
        // 50 ms of tone in 4 s: an RMS of 0.04, a gain of about 3.
        try writeBurst(mic, sampleRate: 16_000, channels: 1, seconds: 4, at: 1.0)
        let short = dir.appendingPathComponent("short.m4a")
        do {
            let source = try AVAudioFile(forReading: mic)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(source.length)))
            try source.read(into: buffer)
            let samples = try #require(buffer.floatChannelData)[0]
            // Keep the first 50 ms of the 200 ms burst.
            for frame in Int(1.05 * 16_000)..<Int(buffer.frameLength) { samples[frame] = 0 }
            let file = try AudioFormat.openAACFile(at: short, sampleRate: 16_000, channels: 1)
            try file.write(from: buffer)
        }
        let output = try #require(AudioFormat.pcmFloat32(sampleRate: 48_000, channels: 1))
        let reader = try MonoLaneReader(file: try AVAudioFile(forReading: short), outputFormat: output)
        let block = try #require(AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 16_384))
        var peak: Float = 0
        while try reader.read(into: block) > 0 {
            let samples = try #require(block.floatChannelData)[0]
            for index in 0..<Int(block.frameLength) { peak = max(peak, abs(samples[index])) }
        }
        #expect(peak > 0.9, "the gain clipped the bursts (peak \(peak))")
        #expect(peak <= 0.97, "peak \(peak)")
    }
}
