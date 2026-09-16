import Testing
import Foundation
@testable import KleothCore

@Suite struct ChatCompletingTests {
    @Test func flattenSplitsSystemFromASingleUserTurn() {
        let messages = [
            ChatMessage(role: "system", content: "Be brief."),
            ChatMessage(role: "user", content: "Hello"),
        ]
        let flat = ChatMessage.flattenForSingleTurn(messages)
        #expect(flat.system == "Be brief.")
        #expect(flat.prompt == "Hello")
    }

    @Test func flattenLabelsMultipleTurns() {
        let messages = [
            ChatMessage(role: "system", content: "S"),
            ChatMessage(role: "user", content: "U1"),
            ChatMessage(role: "assistant", content: "A1"),
            ChatMessage(role: "user", content: "U2"),
        ]
        let flat = ChatMessage.flattenForSingleTurn(messages)
        #expect(flat.system == "S")
        #expect(flat.prompt == "User:\nU1\n\nAssistant:\nA1\n\nUser:\nU2")
    }

    @Test func flattenWithoutSystemHasNilSystem() {
        let flat = ChatMessage.flattenForSingleTurn([ChatMessage(role: "user", content: "x")])
        #expect(flat.system == nil)
        #expect(flat.prompt == "x")
    }

    @Test func summarizerAcceptsAnyChatCompleting() async throws {
        let mock = MockChatClient(results: [.success(ChatCompletion(
            content: #"{"tldr":"t","overview":"o","action_items":[],"per_speaker_highlights":[]}"#,
            usage: nil, finishReason: "stop"))])
        let summarizer = Summarizer(client: mock, model: "any")
        let transcript = Transcript(
            utterances: [Utterance(speakerId: "speaker_0", speakerName: "A", start: 0, end: 1, text: "hi")],
            languageCode: "en", durationSecs: 1)
        let (summary, cost) = try await summarizer.summarize(
            transcript: transcript, metadata: MeetingMetadata(title: "T", date: "2026-09-16"))
        #expect(summary.tldr == "t")
        #expect(cost == 0)
        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].model == "any")
        #expect(mock.calls[0].temperature == nil)
    }
}
