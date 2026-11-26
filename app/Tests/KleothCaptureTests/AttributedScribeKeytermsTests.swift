import AVFoundation
import Foundation
import KleothCore
import Testing
@testable import KleothCapture

/// A meeting's cloud transcription goes through `ChannelAttributedScribeTranscriber`
/// (mic + system mixed to mono, diarized): the personal dictionary must reach
/// the wire as `keyterms` alongside diarization, and an empty one must add
/// nothing. Synthetic tones and a canned transport — no network, no key.
@Suite struct AttributedScribeKeytermsTests {
    /// Records each upload body while the call is in flight (the client deletes
    /// its temporary body file as soon as the upload returns) and answers with
    /// an empty transcript.
    private final class RecordingTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var bodies: [Data] = []

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            try await upload(for: request, fromFile: URL(fileURLWithPath: "/dev/null"))
        }

        func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
            let body = (try? Data(contentsOf: fileURL)) ?? Data()
            lock.withLock { bodies.append(body) }
            let json = #"{"language_code":"eng","language_probability":0.99,"text":"","words":[]}"#
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.test")!,
                statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
            )!
            return (Data(json.utf8), response)
        }
    }

    private func scratchDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-attributed-keyterms-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// One second of a mono sine as a capture lane writes it.
    private func writeTone(_ url: URL, frequency: Double) throws {
        let sampleRate = 48_000.0
        let format = try #require(AudioFormat.pcmFloat32(sampleRate: sampleRate, channels: 1))
        let count = Int(sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        let samples = try #require(buffer.floatChannelData)[0]
        for frame in 0..<count {
            samples[frame] = Float(0.5 * sin(2 * .pi * frequency * Double(frame) / sampleRate))
        }
        // The file is finalized when its last reference goes.
        do {
            let file = try AudioFormat.openAACFile(at: url, sampleRate: sampleRate, channels: 1)
            try file.write(from: buffer)
        }
    }

    private func partValues(named name: String, in body: String) -> [String] {
        let header = "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
        return body.components(separatedBy: header).dropFirst().compactMap { tail in
            tail.range(of: "\r\n").map { String(tail[tail.startIndex..<$0.lowerBound]) }
        }
    }

    /// The text fields of the one request a meeting transcription sends.
    private func sentFields(keyterms: [String]) async throws -> String {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = dir.appendingPathComponent("mic.m4a")
        let system = dir.appendingPathComponent("system.m4a")
        try writeTone(mic, frequency: 300)
        try writeTone(system, frequency: 440)

        let transport = RecordingTransport()
        let transcriber = ChannelAttributedScribeTranscriber(
            scribe: ScribeClient(apiKey: "test-key-not-a-secret", transport: transport),
            micURL: mic,
            systemURL: system
        )
        _ = try await transcriber.transcribe(fileURL: mic, options: .meeting(keyterms: keyterms))

        let body = try #require(transport.bodies.first)
        // Only the text parts before the audio: the audio bytes are not UTF-8.
        let fileHeader = try #require(body.range(of: Data("name=\"file\"".utf8)))
        return String(decoding: body[..<fileHeader.lowerBound], as: UTF8.self)
    }

    @Test func meetingKeytermsReachTheWireWithDiarization() async throws {
        let fields = try await sentFields(keyterms: ["Acmeflow", "Зорблатов"])
        #expect(partValues(named: "keyterms", in: fields) == ["Acmeflow", "Зорблатов"])
        #expect(partValues(named: "diarize", in: fields) == ["true"])
        #expect(partValues(named: "model_id", in: fields) == ["scribe_v2"])
    }

    @Test func emptyVocabularySendsNoKeyterms() async throws {
        let fields = try await sentFields(keyterms: [])
        #expect(!fields.contains("name=\"keyterms\""))
        #expect(partValues(named: "diarize", in: fields) == ["true"])
    }
}
