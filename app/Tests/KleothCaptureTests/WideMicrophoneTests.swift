import AVFoundation
import Foundation
import Testing
@testable import KleothCapture

/// A microphone wider than two channels (a MacBook's built-in array reported
/// 3 ch / 44.1 kHz on macOS 27 with a Bluetooth headset as the output) used to
/// leave a 28-byte `mic.m4a`: the AAC file opened with three channels and
/// refused every write, and the meeting could not be combined or transcribed
/// (2026-11-16). These run the capture's file path on synthetic buffers.
@Suite struct WideMicrophoneTests {
    private static let sampleRate = 44_100.0
    private static let tapSize: AVAudioFrameCount = 4096

    private func scratchURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-capture-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    /// What `inputNode.inputFormat(forBus:)` hands back for a device with
    /// `channels` capsules: Float32 with a discrete layout.
    private func wideFormat(channels: UInt32, interleaved: Bool) throws -> AVAudioFormat {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels))
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, interleaved: interleaved, channelLayout: layout
        )
    }

    /// One tap buffer with a 440 Hz tone at `amplitude` on every channel in
    /// `voiced`, silence on the rest.
    private func toneBuffer(
        _ format: AVAudioFormat, frames: AVAudioFrameCount, voiced: Set<Int>, amplitude: Float = 0.5
    ) throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let planes = try #require(buffer.floatChannelData)
        let channels = Int(format.channelCount)
        for frame in 0..<Int(frames) {
            let sample = amplitude * sinf(2 * .pi * 440 * Float(frame) / Float(Self.sampleRate))
            for channel in 0..<channels {
                let value = voiced.contains(channel) ? sample : 0
                if format.isInterleaved {
                    planes[0][frame * channels + channel] = value
                } else {
                    planes[channel][frame] = value
                }
            }
        }
        return buffer
    }

    /// The loudest sample of the file's first channel, and its length.
    private func readBack(_ url: URL) throws -> (frames: AVAudioFramePosition, channels: UInt32, peak: Float) {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData)[0]
        var peak: Float = 0
        for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[index])) }
        return (file.length, file.processingFormat.channelCount, peak)
    }

    @Test func fileNeverGetsMoreThanTwoChannels() {
        #expect(AudioFormat.fileChannels(forSource: 1) == 1)
        #expect(AudioFormat.fileChannels(forSource: 2) == 2)
        #expect(AudioFormat.fileChannels(forSource: 3) == 1)
        #expect(AudioFormat.fileChannels(forSource: 6) == 1)
        #expect(AudioFormat.fileChannels(forSource: 0) == 1)
    }

    /// The meeting and dictation path: open the file for the device's channel
    /// count, write tap buffers through `TapWriter`, close, read back.
    @Test(arguments: [true, false])
    func threeChannelMicrophoneIsRecorded(interleaved: Bool) throws {
        let source = try wideFormat(channels: 3, interleaved: interleaved)
        let url = scratchURL("mic.m4a")
        var written: AVAudioFrameCount = 0
        // The file is finalized when its last reference goes: the scope ends
        // the writer's too.
        do {
            let file = try AudioFormat.openAACFile(at: url, sampleRate: source.sampleRate, channels: 3)
            let writer = try #require(TapWriter(file: file, sourceFormat: source, bufferSize: Self.tapSize))
            for _ in 0..<12 {
                // The voice on the LAST capsule only: a mix that kept just the
                // first channel would read back silent.
                written += try writer.write(try toneBuffer(source, frames: Self.tapSize, voiced: [2]))
            }
        }

        #expect(written == 12 * Self.tapSize)
        let result = try readBack(url)
        #expect(result.channels == 1)
        #expect(result.frames >= AVAudioFramePosition(12 * Self.tapSize))
        // One voiced capsule of three at 0.5 averages to about 0.17.
        #expect(result.peak > 0.1)
        #expect(Recorder.holdsAudio(url))
    }

    /// A three-channel source at one rate into a file opened at another (the
    /// device changed mid-meeting): mixed down, then resampled.
    @Test func wideSourceIsResampledIntoAnOpenFile() throws {
        let source = try wideFormat(channels: 3, interleaved: false)
        let url = scratchURL("mic.m4a")
        do {
            let file = try AudioFormat.openAACFile(at: url, sampleRate: 16_000, channels: 1)
            let writer = try #require(TapWriter(file: file, sourceFormat: source, bufferSize: Self.tapSize))
            for _ in 0..<12 {
                _ = try writer.write(try toneBuffer(source, frames: Self.tapSize, voiced: [0, 1, 2]))
            }
        }

        let result = try readBack(url)
        #expect(result.channels == 1)
        #expect(result.peak > 0.3)
    }

    @Test func downmixAveragesEveryChannel() throws {
        let source = try wideFormat(channels: 3, interleaved: false)
        let downmix = try #require(MonoDownmix(source: source, bufferSize: Self.tapSize))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 8))
        buffer.frameLength = 8
        let planes = try #require(buffer.floatChannelData)
        for frame in 0..<8 {
            planes[0][frame] = 0.3
            planes[1][frame] = 0.6
            planes[2][frame] = 0.9
        }

        let mono = try #require(downmix.mix(buffer))

        let stereo = try #require(AudioFormat.pcmFloat32(sampleRate: 48_000, channels: 2))
        #expect(mono.frameLength == 8)
        #expect(mono.format.channelCount == 1)
        let out = try #require(mono.floatChannelData)[0]
        #expect(abs(out[0] - 0.6) < 0.0001)
        #expect(abs(out[7] - 0.6) < 0.0001)
        #expect(!MonoDownmix.isNeeded(for: stereo))
    }

    /// The stop path with a dead microphone lane: the header-only `mic.m4a`
    /// must not cost the meeting its combined file.
    @Test func combineSurvivesAHeaderOnlyMicrophoneFile() throws {
        let dir = scratchURL("x").deletingLastPathComponent()
        let mic = dir.appendingPathComponent("mic.m4a")
        let system = dir.appendingPathComponent("system.m4a")
        let combined = dir.appendingPathComponent("meeting.m4a")
        // Exactly what the failed capture left: the 28-byte `ftyp` box.
        let header: [UInt8] = [0, 0, 0, 0x1c, 0x66, 0x74, 0x79, 0x70, 0x4d, 0x34, 0x41, 0x20, 0, 0, 0, 0,
                               0x4d, 0x34, 0x41, 0x20, 0x6d, 0x70, 0x34, 0x32, 0x69, 0x73, 0x6f, 0x6d]
        try Data(header).write(to: mic)
        let stereo = try #require(AudioFormat.pcmFloat32(sampleRate: 48_000, channels: 2))
        var file: AVAudioFile? = try AudioFormat.openAACFile(at: system, sampleRate: 48_000, channels: 2)
        try file?.write(from: try toneBuffer(stereo, frames: 48_000, voiced: [0, 1]))
        file = nil

        #expect(!Recorder.holdsAudio(mic))
        #expect(Recorder.holdsAudio(system))
        try Recorder.combineChannels(micURL: mic, systemURL: system, outputURL: combined)

        let result = try readBack(combined)
        #expect(result.channels == 2)
        #expect(result.frames >= 48_000)
        #expect(result.peak < 0.001)   // channel 0 is the microphone: silent
        let whole = try AVAudioFile(forReading: combined)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: whole.processingFormat, frameCapacity: AVAudioFrameCount(whole.length)))
        try whole.read(into: buffer)
        let other = try #require(buffer.floatChannelData)[1]
        var peak: Float = 0
        for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(other[index])) }
        #expect(peak > 0.05, "peak \(peak)")   // channel 1 carries the other side (loudness-normalized)
    }
}
