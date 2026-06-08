import Testing
import Foundation
@testable import KleothCore

@Suite struct SummaryDecodeTests {
    // MARK: - Test data builders

    /// A valid MeetingSummary as the model would emit it (snake_case JSON).
    static let summaryJSON = """
    {
      "tldr": "Shipped the beta; agreed on a launch date.",
      "overview": "The team reviewed the beta rollout in detail and settled on June 10 as the launch date.",
      "action_items": [
        { "owner": "alice", "task": "Write changelog", "due": "2026-06-05" },
        { "owner": "unassigned", "task": "Book the venue", "due": null }
      ],
      "per_speaker_highlights": [
        { "speaker": "Alice", "highlights": ["Owns changelog"] }
      ]
    }
    """

    /// Wraps `content` as the OpenRouter chat-completions response envelope,
    /// embedding it as the assistant message content (JSON-escaped).
    static func completionEnvelope(content: String, cost: Double? = nil, finishReason: String? = nil) -> String {
        let escaped = escapeForJSONString(content)
        let finish = finishReason.map { ", \"finish_reason\": \"\($0)\"" } ?? ""
        let usage = cost.map { ", \"usage\": { \"cost\": \($0) }" } ?? ""
        return "{ \"choices\": [ { \"message\": { \"role\": \"assistant\", \"content\": \"\(escaped)\" }\(finish) } ]\(usage) }"
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
          "tldr": "x", "overview": "o", "action_items": [], "per_speaker_highlights": []
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let summary = try decoder.decode(MeetingSummary.self, from: Data(json.utf8))
        #expect(summary.title == "Q3 Launch Planning")
        #expect(summary.overview == "o")
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

    /// A legacy summary.json (the pre-2026-06-04 shape with decisions /
    /// key_points / open_questions / suggested_tags and no "overview") still
    /// decodes: removed keys are ignored, `overview` is nil, and the kept
    /// fields come through intact.
    @Test func summaryDecodesLegacyShape() throws {
        let legacy = """
        {
          "tldr": "Old-shape summary.",
          "decisions": ["Launch June 10"],
          "action_items": [{ "owner": "alice", "task": "Write changelog", "due": null }],
          "key_points": ["Feedback positive"],
          "per_speaker_highlights": [{ "speaker": "Alice", "highlights": ["Owns changelog"] }],
          "open_questions": ["Press release?"],
          "suggested_tags": ["launch"]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let summary = try decoder.decode(MeetingSummary.self, from: Data(legacy.utf8))
        #expect(summary.tldr == "Old-shape summary.")
        #expect(summary.overview == nil)
        #expect(summary.actionItems.count == 1)
        #expect(summary.perSpeakerHighlights.first?.speaker == "Alice")
    }

    /// A provider's looser `json_object` fallback may omit the arrays entirely;
    /// they decode as empty rather than failing the whole summary.
    @Test func summaryDecodesWithMissingArraysAsEmpty() throws {
        let sparse = """
        { "tldr": "Just the gist." }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let summary = try decoder.decode(MeetingSummary.self, from: Data(sparse.utf8))
        #expect(summary.actionItems.isEmpty)
        #expect(summary.perSpeakerHighlights.isEmpty)
        #expect(summary.overview == nil)
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
        #expect(summary.overview?.contains("June 10") == true)
        #expect(summary.actionItems.count == 2)
        #expect(summary.actionItems[0].owner == "alice")
        #expect(summary.actionItems[0].task == "Write changelog")
        #expect(summary.actionItems[0].due == "2026-06-05")
        // null due maps to nil.
        #expect(summary.actionItems[1].due == nil)
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

    // MARK: - Output language preservation (a RU transcript must not be summarized in EN)

    /// Joins every message's `content` from the first recorded chat-completions
    /// request body, so tests can assert what the model was actually told to do.
    private static func sentMessageText(_ transport: MockTransport) throws -> String {
        let body = try #require(transport.recordedRequests.first?.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let messages = (json?["messages"] as? [[String: Any]]) ?? []
        return messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
    }

    /// A Russian transcript must make the summarizer instruct the model to write
    /// the summary in Russian. Root cause of "RU meeting → EN summary": the
    /// prompt never named an output language, so the model defaulted to English.
    @Test func summarizeInstructsModelToUseTranscriptLanguage() async throws {
        let transport = MockTransport(json: Self.completionEnvelope(content: Self.summaryJSON))
        let summarizer = makeSummarizer(transport)
        let russian = Transcript(
            utterances: [Utterance(speakerId: "speaker_0", speakerName: "You", text: "Привет, давай по датасету.")],
            languageCode: "rus",   // ElevenLabs Scribe reports 3-letter codes; Whisper reports "ru".
            durationSecs: 1
        )

        _ = try await summarizer.summarize(transcript: russian, metadata: metadata())

        let sent = try Self.sentMessageText(transport)
        #expect(sent.contains("Russian"))
        #expect(sent.localizedCaseInsensitiveContains("same language"))
    }

    /// Even with no detected language, the model is told to match the
    /// transcript's language rather than silently translating it.
    @Test func summarizeInstructsSameLanguageWhenUnknown() async throws {
        let transport = MockTransport(json: Self.completionEnvelope(content: Self.summaryJSON))
        let summarizer = makeSummarizer(transport)
        let unknown = Transcript(
            utterances: [Utterance(speakerId: "speaker_0", speakerName: "You", text: "…")],
            languageCode: nil,
            durationSecs: 1
        )

        _ = try await summarizer.summarize(transcript: unknown, metadata: metadata())

        let sent = try Self.sentMessageText(transport)
        #expect(sent.localizedCaseInsensitiveContains("same language"))
    }

    /// `languageName(for:)` maps the codes the pipeline actually emits — 3-letter
    /// (Scribe) and 2-letter (Whisper) — to an English language name, and leaves
    /// an unknown code intact rather than inventing one.
    @Test func languageNameMapsCommonCodes() {
        #expect(Summarizer.languageName(for: "rus") == "Russian")
        #expect(Summarizer.languageName(for: "ru") == "Russian")
        #expect(Summarizer.languageName(for: "en") == "English")
        #expect(Summarizer.languageName(for: "eng") == "English")
        #expect(Summarizer.languageName(for: nil) == nil)
        #expect(Summarizer.languageName(for: "") == nil)
    }

    // MARK: - Truncation handling (finish_reason == "length")

    /// A first response truncated at the output cap (`finish_reason == "length"`)
    /// must be retried even though it would decode leniently (a summary cut off
    /// after `tldr` is silently gutted, not "complete"). The retry's complete
    /// response is what's returned.
    @Test func summarizeRetriesOnTruncatedFirstResponse() async throws {
        let truncated = Self.completionEnvelope(
            content: "{ \"tldr\": \"Only the tldr made it before the cap.\" }",
            cost: 0.01,
            finishReason: "length"
        )
        let complete = Self.completionEnvelope(content: Self.summaryJSON, cost: 0.02, finishReason: "stop")
        let transport = MockTransport(jsonSequence: [truncated, complete])
        let summarizer = makeSummarizer(transport)

        let (summary, costUSD) = try await summarizer.summarize(
            transcript: transcript(),
            metadata: metadata()
        )

        // The complete retry — not the truncated first — is returned.
        #expect(summary.overview?.contains("June 10") == true)
        #expect(summary.actionItems.count == 2)
        #expect(abs(costUSD - 0.03) < 1e-9)
        #expect(transport.callCount == 2)
    }

    /// If the retry is also truncated, fail loudly (so the pipeline records a
    /// `summaryError` and keeps the transcript) rather than shipping a partial
    /// summary as if it were complete.
    @Test func summarizeThrowsWhenTruncationPersists() async {
        let truncated = Self.completionEnvelope(
            content: "{ \"tldr\": \"partial\" }",
            finishReason: "length"
        )
        let transport = MockTransport(jsonSequence: [truncated, truncated])
        let summarizer = makeSummarizer(transport)

        do {
            _ = try await summarizer.summarize(transcript: transcript(), metadata: metadata())
            Issue.record("Expected SummarizerError.invalidJSON on persistent truncation")
        } catch let error as SummarizerError {
            guard case .invalidJSON = error else {
                Issue.record("Expected .invalidJSON, got \(error)")
                return
            }
            #expect(transport.callCount == 2)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    /// A complete short answer (`finish_reason == "stop"`) is accepted on the
    /// first try — the truncation guard must not over-reject valid output.
    @Test func summarizeAcceptsCompleteResponseOnFirstTry() async throws {
        let transport = MockTransport(
            json: Self.completionEnvelope(content: Self.summaryJSON, cost: 0.01, finishReason: "stop")
        )
        let summarizer = makeSummarizer(transport)
        let (summary, _) = try await summarizer.summarize(transcript: transcript(), metadata: metadata())
        #expect(summary.tldr == "Shipped the beta; agreed on a launch date.")
        #expect(transport.callCount == 1)
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
