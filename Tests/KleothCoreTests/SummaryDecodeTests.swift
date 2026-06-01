import Testing
import Foundation
@testable import KleothCore

@Suite struct SummaryDecodeTests {
    // MARK: - Test data builders

    /// A valid MeetingSummary as the model would emit it (snake_case JSON).
    static let summaryJSON = """
    {
      "tldr": "Shipped the beta; agreed on a launch date.",
      "decisions": ["Launch June 10"],
      "action_items": [
        { "owner": "alice", "task": "Write changelog", "due": "2026-06-05" },
        { "owner": "unassigned", "task": "Book the venue", "due": null }
      ],
      "key_points": ["Feedback positive"],
      "per_speaker_highlights": [
        { "speaker": "Alice", "highlights": ["Owns changelog"] }
      ],
      "open_questions": ["Press release?"],
      "suggested_tags": ["launch"]
    }
    """

    /// Wraps `content` as the OpenRouter chat-completions response envelope,
    /// embedding it as the assistant message content (JSON-escaped).
    static func completionEnvelope(content: String, cost: Double? = nil) -> String {
        let escaped = escapeForJSONString(content)
        let usage = cost.map { ", \"usage\": { \"cost\": \($0) }" } ?? ""
        return "{ \"choices\": [ { \"message\": { \"role\": \"assistant\", \"content\": \"\(escaped)\" } } ]\(usage) }"
    }

    static func escapeForJSONString(_ raw: String) -> String {
        var out = ""
        for ch in raw.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    private func transcript() -> Transcript {
        Transcript(
            utterances: [
                Utterance(speakerId: "speaker_0", speakerName: "Alice", start: 0, end: 1, text: "Let's launch June 10."),
                Utterance(speakerId: "speaker_1", speakerName: "Bob", start: 1.5, end: 2.5, text: "Agreed."),
            ],
            languageCode: "en",
            durationSecs: 2.5
        )
    }

    private func metadata() -> MeetingMetadata {
        MeetingMetadata(title: "Launch", date: "2026-05-30", participants: ["Alice", "Bob"])
    }

    private func makeSummarizer(_ transport: MockTransport) -> Summarizer {
        Summarizer(client: OpenRouterClient(apiKey: "test-key", transport: transport))
    }

    // MARK: - title (optional, back-compatible)

    /// A summary JSON that includes "title" decodes it.
    @Test func summaryDecodesTitleWhenPresent() throws {
        let json = """
        {
          "title": "Q3 Launch Planning",
          "tldr": "x", "decisions": [], "action_items": [], "key_points": [],
          "per_speaker_highlights": [], "open_questions": [], "suggested_tags": []
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let summary = try decoder.decode(MeetingSummary.self, from: Data(json.utf8))
        #expect(summary.title == "Q3 Launch Planning")
    }

    /// An older summary JSON without "title" decodes with title == nil.
    @Test func summaryDecodesNilTitleWhenAbsent() throws {
        // Self.summaryJSON has no "title" field.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let summary = try decoder.decode(MeetingSummary.self, from: Data(Self.summaryJSON.utf8))
        #expect(summary.title == nil)
        // Other fields still decode as before.
        #expect(summary.tldr == "Shipped the beta; agreed on a launch date.")
    }

    // MARK: - stripCodeFences (the ```json blob handling)

    @Test func stripCodeFencesRemovesJSONFence() {
        let fenced = "```json\n{\"a\":1}\n```"
        #expect(Summarizer.stripCodeFences(fenced) == "{\"a\":1}")
    }

    @Test func stripCodeFencesRemovesBareFence() {
        let fenced = "```\n{\"a\":1}\n```"
        #expect(Summarizer.stripCodeFences(fenced) == "{\"a\":1}")
    }

    @Test func stripCodeFencesLeavesUnfencedContent() {
        #expect(Summarizer.stripCodeFences("{\"a\":1}") == "{\"a\":1}")
    }

    // MARK: - Decode a ```json-fenced blob end-to-end via summarize

    @Test func summarizeDecodesJSONFencedBlobOnFirstTry() async throws {
        let fenced = "```json\n\(Self.summaryJSON)\n```"
        let transport = MockTransport(json: Self.completionEnvelope(content: fenced, cost: 0.0123))
        let summarizer = makeSummarizer(transport)

        let (summary, costUSD) = try await summarizer.summarize(
            transcript: transcript(),
            metadata: metadata()
        )

        #expect(summary.tldr == "Shipped the beta; agreed on a launch date.")
        #expect(summary.decisions == ["Launch June 10"])
        #expect(summary.actionItems.count == 2)
        #expect(summary.actionItems[0].owner == "alice")
        #expect(summary.actionItems[0].task == "Write changelog")
        #expect(summary.actionItems[0].due == "2026-06-05")
        // null due maps to nil.
        #expect(summary.actionItems[1].due == nil)
        #expect(summary.suggestedTags == ["launch"])
        #expect(abs(costUSD - 0.0123) < 1e-9)

        // Only one round trip needed.
        #expect(transport.callCount == 1)
    }

    @Test func summarizeDecodesPlainJSONObject() async throws {
        let transport = MockTransport(json: Self.completionEnvelope(content: Self.summaryJSON))
        let summarizer = makeSummarizer(transport)

        let (summary, _) = try await summarizer.summarize(
            transcript: transcript(),
            metadata: metadata()
        )
        #expect(summary.actionItems[1].owner == "unassigned")
        #expect(transport.callCount == 1)
    }

    // MARK: - One-shot repair path (bad-then-good) via MockTransport

    @Test func summarizeRepairsBadJSONOnSecondAttempt() async throws {
        let badContent = "Sure! Here is your summary in prose, not JSON at all."
        let goodContent = Self.summaryJSON

        let transport = MockTransport(jsonSequence: [
            Self.completionEnvelope(content: badContent, cost: 0.01),  // first: unusable
            Self.completionEnvelope(content: goodContent, cost: 0.02), // repair: valid
        ])
        let summarizer = makeSummarizer(transport)

        let (summary, costUSD) = try await summarizer.summarize(
            transcript: transcript(),
            metadata: metadata()
        )

        // The repaired summary is returned.
        #expect(summary.tldr == "Shipped the beta; agreed on a launch date.")
        // Cost accumulates across both attempts.
        #expect(abs(costUSD - 0.03) < 1e-9)
        // Exactly two requests were made: original + one repair.
        #expect(transport.callCount == 2)
    }

    @Test func summarizeThrowsWhenRepairAlsoFails() async {
        let bad = Self.completionEnvelope(content: "still not json")
        // Both attempts return bad content (the sequence's last element replays,
        // but two distinct bad entries make the intent explicit).
        let transport = MockTransport(jsonSequence: [bad, bad])
        let summarizer = makeSummarizer(transport)

        do {
            _ = try await summarizer.summarize(transcript: transcript(), metadata: metadata())
            Issue.record("Expected SummarizerError.invalidJSON")
        } catch let error as SummarizerError {
            guard case .invalidJSON = error else {
                Issue.record("Expected .invalidJSON, got \(error)")
                return
            }
            // Expected: two attempts (original + repair), then give up.
            #expect(transport.callCount == 2)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
