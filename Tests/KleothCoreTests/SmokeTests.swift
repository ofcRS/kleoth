import Testing
import Foundation
@testable import KleothCore

@Suite struct SmokeTests {
    /// Trivial test so the test target has at least one source and the
    /// frozen contract is exercised at the type level.
    @Test func modelsConstructAndEncode() throws {
        let utterance = Utterance(speakerId: "speaker_0", start: 0.0, end: 1.0, text: "Hi")
        let transcript = Transcript(utterances: [utterance], languageCode: "en", durationSecs: 1.0)
        #expect(transcript.utterances.count == 1)

        let cost = CostBreakdown(transcriptionUSD: 0.10, summaryUSD: 0.05)
        #expect(abs(cost.totalUSD - 0.15) < 1e-9)

        // Round-trip a model through JSON to confirm Codable conformance.
        let data = try JSONEncoder().encode(transcript)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)
        #expect(decoded.utterances.first?.text == "Hi")
    }
}
