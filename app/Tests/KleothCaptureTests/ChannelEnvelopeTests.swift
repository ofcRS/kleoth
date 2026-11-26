import AVFoundation
import Foundation
import Testing
@testable import KleothCapture

/// `ChannelAudio.envelope` (the per-hop RMS speaker attribution reads) is read
/// in chunks: the same values as the whole lane decoded at once, hop for hop,
/// of the first channel, with a shorter last hop.
@Suite struct ChannelEnvelopeTests {
    private func scratchDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-envelope-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A lossless float file: channel 0 steps through amplitudes every 0.3 s,
    /// channel 1 is louder and constant.
    private func writeSteps(_ url: URL, sampleRate: Double, seconds: Double) throws -> [Float] {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ]
        let total = Int((seconds * sampleRate).rounded())
        let format = try #require(AudioFormat.pcmFloat32(sampleRate: sampleRate, channels: 2))
        var left = [Float](repeating: 0, count: total)
        for i in 0..<total {
            let step = Int(Double(i) / sampleRate / 0.3)
            left[i] = Float([0.05, 0.4, 0, 0.2][step % 4]) * (i % 2 == 0 ? 1 : -1)
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)))
            buffer.frameLength = AVAudioFrameCount(total)
            let planes = try #require(buffer.floatChannelData)
            for i in 0..<total {
                planes[0][i] = left[i]
                planes[1][i] = 0.9
            }
            try file.write(from: buffer)
        }
        return left
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        let meanSquare = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        return meanSquare > 0 ? meanSquare.squareRoot() : 0
    }

    @Test func matchesTheWholeLaneHopForHop() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("system.caf")
        // 3.53 s at 48 kHz: 71 hops of 50 ms, the last one 30 ms; past one chunk.
        let left = try writeSteps(url, sampleRate: 48_000, seconds: 3.53)

        let envelope = try ChannelAudio.envelope(of: url, hopSeconds: 0.05)
        let hop = 2400
        let expected = stride(from: 0, to: left.count, by: hop).map { rms(left[$0..<min(left.count, $0 + hop)]) }
        #expect(envelope.count == expected.count)
        for (got, want) in zip(envelope, expected) {
            #expect(abs(got - want) < 1e-4)
        }
    }

    @Test func aHeaderOnlyOrMissingLaneHasNoEnvelope() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let headerOnly = dir.appendingPathComponent("mic.m4a")
        try Data([0, 0, 0, 28]).write(to: headerOnly)
        #expect(try ChannelAudio.envelope(of: headerOnly, hopSeconds: 0.05).isEmpty)
        #expect(try ChannelAudio.envelope(of: dir.appendingPathComponent("none.m4a"), hopSeconds: 0.05).isEmpty)
    }

    /// An AAC lane, as captured: one value per hop, at the tone's RMS.
    @Test func readsACompressedLane() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mic.m4a")
        let sampleRate = 16_000.0
        let format = try #require(AudioFormat.pcmFloat32(sampleRate: sampleRate, channels: 1))
        let total = Int(2 * sampleRate)
        do {
            let file = try AudioFormat.openAACFile(at: url, sampleRate: sampleRate, channels: 1)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)))
            buffer.frameLength = AVAudioFrameCount(total)
            let plane = try #require(buffer.floatChannelData)[0]
            for i in 0..<total { plane[i] = Float(0.5 * sin(2 * .pi * 300 * Double(i) / sampleRate)) }
            try file.write(from: buffer)
        }
        let envelope = try ChannelAudio.envelope(of: url, hopSeconds: 0.05)
        let length = try AVAudioFile(forReading: url).length
        #expect(envelope.count == Int((Double(length) / 800).rounded(.up)))
        let middle = envelope[envelope.count / 4..<envelope.count * 3 / 4]
        #expect(middle.allSatisfy { abs($0 - 0.354) < 0.03 })
    }
}
