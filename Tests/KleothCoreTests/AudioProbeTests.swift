import Testing
import Foundation
import AVFoundation
@testable import KleothCore

/// Covers fix #1: the meeting's wall-clock duration is derived from the actual
/// audio FILE, not the (for multi-channel Scribe, doubled) STT-reported value.
@Suite struct AudioProbeTests {
    /// Writes a short silent mono AAC `.m4a` of `seconds` and returns its URL.
    private func makeM4A(seconds: Double, sampleRate: Double = 48_000) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-probe-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames // zero-filled => silence
        try file.write(from: buffer)
        return url
    }

    @Test func durationMatchesWrittenLength() throws {
        let url = try makeM4A(seconds: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let duration = AudioProbe.durationSeconds(of: url)
        #expect(duration != nil)
        // AAC priming/rounding makes this approximate.
        #expect(abs((duration ?? 0) - 0.5) < 0.2)
    }

    @Test func bogusFileReturnsNil() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-bogus-\(UUID().uuidString).m4a")
        try Data("not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(AudioProbe.durationSeconds(of: url) == nil)
    }

    /// The pipeline must prefer the real ~0.5s file duration over a transcriber
    /// that reports a wildly wrong (e.g. channel-summed 2×) duration.
    @Test func pipelinePrefersFileDurationOverResponse() async throws {
        let url = try makeM4A(seconds: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }

        let transcriber = FixedResponseTranscriber(response: ScribeResponse(
            words: [ScribeWord(text: "x", start: 0, end: 0.2, type: "word", speakerId: "speaker_0")],
            audioDurationSecs: 9_999 // deliberately wrong, like Scribe's 2× multichannel value
        ))
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-probe-pipe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let pipeline = MeetingPipeline(transcriber: transcriber, summarizer: nil, store: MeetingStore(baseDir: baseDir))

        let result = try await pipeline.run(
            audioFile: url,
            metadata: MeetingMetadata(title: "Probe", date: "2026-06-01"),
            options: ScribeOptions(),
            summarize: false
        )

        // Duration comes from the 0.5s file, NOT the 9999s the transcriber reported.
        #expect((result.cost.audioDurationSecs ?? 0) < 5)
        #expect(abs((result.cost.audioDurationSecs ?? 0) - 0.5) < 0.2)
    }
}

/// On-device-style transcriber returning a canned response (bills the Scribe rate).
private struct FixedResponseTranscriber: Transcriber {
    let response: ScribeResponse
    var usdPerHour: Double { 0.22 }
    func transcribe(fileURL: URL, options: ScribeOptions) async throws -> ScribeResponse { response }
}
