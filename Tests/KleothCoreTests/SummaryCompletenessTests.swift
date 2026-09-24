import Testing
import Foundation
@testable import KleothCore

/// When a model answer becomes a summary, and the shape of the one retry
/// (docs/plans/2026-09-24-summary-truncation-and-onboarding-skip.md §3.1–3.2).
/// Every provider reaches `Summarizer` through `ChatCompleting`, so the mock
/// stands in for all of them: the rule must hold whatever finish reason a
/// backend reports.
@Suite struct SummaryCompletenessTests {
    // MARK: - Fixtures

    /// An answer with every key the prompt asks for.
    static let completeAnswer =
        #"{"title":"T","tldr":"t","overview":"o","action_items":[],"per_speaker_highlights":[]}"#

    /// What `completeAnswer` ends in. The partial answers below carry no title,
    /// so this ending also proves it was the retry's answer that came back.
    static let completeEnding = Ending.summary(title: "T", tldr: "t")

    static func answer(_ content: String, finish: String? = "stop") -> Result<ChatCompletion, any Error> {
        .success(ChatCompletion(content: content, finishReason: finish))
    }

    static func transcript() -> Transcript {
        Transcript(
            utterances: [
                Utterance(speakerId: "speaker_0", speakerName: "Alice", start: 0, end: 1, text: "Let's launch June 10."),
                Utterance(speakerId: "speaker_1", speakerName: "Bob", start: 1.5, end: 2.5, text: "Agreed."),
            ],
            languageCode: "en",
            durationSecs: 2.5
        )
    }

    static func metadata() -> MeetingMetadata {
        MeetingMetadata(title: "Launch", date: "2026-05-30", participants: ["Alice", "Bob"])
    }

    /// How a run ended, reduced to what these tests compare.
    enum Ending: Equatable {
        case summary(title: String?, tldr: String)
        case truncated
        case incomplete(missing: [String])
        case invalidJSON(snippet: String)
        case httpError(status: Int)
        case other(String)

        init(_ error: any Error) {
            switch error {
            case SummarizerError.truncated: self = .truncated
            case let SummarizerError.incomplete(missing): self = .incomplete(missing: missing)
            case let SummarizerError.invalidJSON(snippet): self = .invalidJSON(snippet: snippet)
            case let OpenRouterError.httpError(status, _): self = .httpError(status: status)
            default: self = .other(String(describing: error))
            }
        }
    }

    struct Run {
        let ending: Ending
        /// The user-facing message of the error it ended in; nil for a summary.
        let message: String?
        let calls: [MockChatClient.Call]
    }

    /// Summarizes the fixture transcript against `answers`, served in order.
    /// Without `maxOutputTokens` the summarizer is built the way every existing
    /// call site builds it: on the default budget.
    static func run(_ answers: [Result<ChatCompletion, any Error>], maxOutputTokens: Int? = nil) async -> Run {
        let client = MockChatClient(results: answers)
        let summarizer = maxOutputTokens.map { Summarizer(client: client, model: "m", maxOutputTokens: $0) }
            ?? Summarizer(client: client, model: "m")
        do {
            let (summary, _) = try await summarizer.summarize(transcript: transcript(), metadata: metadata())
            return Run(ending: .summary(title: summary.title, tldr: summary.tldr), message: nil, calls: client.calls)
        } catch {
            return Run(ending: Ending(error), message: error.localizedDescription, calls: client.calls)
        }
    }

    // MARK: - The retry after a cut-off

    /// Codex, Claude Code and local servers can report "stop" for a cut-off
    /// answer. A JSON object that stops mid-string is still a cut-off: it is
    /// asked again fresh (the original two messages plus the compact
    /// instruction) at twice the budget, not replayed as bad JSON at the same cap.
    @Test func cutOffJSONWithoutLengthIsReaskedFresh() async throws {
        let run = await Self.run([
            Self.answer(#"{"tldr":"a","overview":"b"#, finish: "stop"),
            Self.answer(Self.completeAnswer),
        ])
        #expect(run.ending == Self.completeEnding)
        try #require(run.calls.count == 2)
        #expect(run.calls[0].maxTokens == 8192)
        #expect(run.calls[1].maxTokens == 16384)
        let first = run.calls[0].messages, retry = run.calls[1].messages
        try #require(retry.count == 2)
        #expect(retry[0].content == first[0].content)
        #expect(retry[1].content.hasPrefix(first[1].content))
        #expect(retry[1].content.hasSuffix(Summarizer.compactRetryInstruction))
    }

    /// Nothing came back and the cap was hit: the budget went on reasoning, so
    /// the retry asks for less of it. The first request never sends `reasoning`.
    @Test func cutOffWithNoTextRetriesWithLowReasoning() async throws {
        let run = await Self.run([Self.answer("", finish: "length"), Self.answer(Self.completeAnswer)])
        #expect(run.ending == Self.completeEnding)
        try #require(run.calls.count == 2)
        #expect(run.calls[0].reasoning == nil)
        #expect(run.calls[1].reasoning == .low)
        #expect(run.calls[1].maxTokens == 16384)
        try #require(run.calls[1].messages.count == 2)
        #expect(run.calls[1].messages[1].content.hasSuffix(Summarizer.compactRetryInstruction))
    }

    /// Text came back before the cap, so the budget went on the answer:
    /// reasoning stays unset, and the retry is still fresh and compact.
    @Test func cutOffWithTextLeavesReasoningUnset() async throws {
        let run = await Self.run([Self.answer(#"{"tldr":"a""#, finish: "length"), Self.answer(Self.completeAnswer)])
        #expect(run.ending == Self.completeEnding)
        try #require(run.calls.count == 2)
        #expect(run.calls[1].reasoning == nil)
        try #require(run.calls[1].messages.count == 2)
        #expect(run.calls[1].messages[1].content.hasSuffix(Summarizer.compactRetryInstruction))
    }

    // MARK: - The retry after an empty answer

    /// An empty answer that wasn't cut off is asked again unchanged. Replayed as
    /// an empty assistant turn it makes Anthropic's API (and strict
    /// OpenAI-compatible upstreams) answer HTTP 400.
    @Test func emptyAnswerIsNotReplayed() async throws {
        let run = await Self.run([Self.answer("", finish: "stop"), Self.answer(Self.completeAnswer)])
        #expect(run.ending == Self.completeEnding)
        try #require(run.calls.count == 2)
        #expect(run.calls[1].maxTokens == 8192)
        #expect(run.calls[1].reasoning == nil)
        let first = run.calls[0].messages, retry = run.calls[1].messages
        try #require(retry.count == 2)
        #expect(retry[0].content == first[0].content)
        #expect(retry[1].content == first[1].content)
    }

    // MARK: - Completeness

    /// A complete JSON object with parts missing is not a summary: the retry
    /// carries the answer and names the parts as the prompt spells them.
    @Test func missingPartsAreRepairedNotAccepted() async throws {
        let first = #"{"tldr":"t"}"#
        let run = await Self.run([Self.answer(first), Self.answer(Self.completeAnswer)])
        #expect(run.ending == Self.completeEnding)
        try #require(run.calls.count == 2)
        #expect(run.calls[1].maxTokens == 8192)
        let retry = run.calls[1].messages
        try #require(retry.count == 4)
        #expect(retry[2].role == "assistant")
        #expect(retry[2].content == first)
        #expect(retry[3].role == "user")
        #expect(retry[3].content == "Your previous answer is missing: overview, action_items, per_speaker_highlights. Return the complete JSON object with every key — no prose, no markdown fences.")
    }

    /// Key drift on the `json_object` path: `summary` where the prompt says
    /// `overview`. The parts that are there count; only the overview is asked for.
    @Test func keyDriftCountsAsMissingOverview() async throws {
        let run = await Self.run([
            Self.answer(#"{"tldr":"t","summary":"s","action_items":[],"per_speaker_highlights":[]}"#),
            Self.answer(Self.completeAnswer),
        ])
        #expect(run.ending == Self.completeEnding)
        try #require(run.calls.count == 2)
        try #require(run.calls[1].messages.count == 4)
        #expect(run.calls[1].messages[3].content == "Your previous answer is missing: overview. Return the complete JSON object with every key — no prose, no markdown fences.")
    }

    /// A blank TL;DR is no TL;DR.
    @Test func blankTLDRIsIncomplete() async throws {
        let run = await Self.run([
            Self.answer(#"{"title":"T","tldr":"  ","overview":"o","action_items":[],"per_speaker_highlights":[]}"#),
            Self.answer(Self.completeAnswer),
        ])
        #expect(run.ending == Self.completeEnding)
        try #require(run.calls.count == 2)
        try #require(run.calls[1].messages.count == 4)
        #expect(run.calls[1].messages[3].content == "Your previous answer is missing: tldr. Return the complete JSON object with every key — no prose, no markdown fences.")
    }

    /// Key drift can hit the TL;DR too: `summary` where the prompt says `tldr`.
    /// That is a JSON object with a part missing, not invalid JSON, so the
    /// repair names `tldr`.
    @Test func keyDriftCountsAsMissingTLDR() async throws {
        let run = await Self.run([
            Self.answer(#"{"summary":"s","overview":"o","action_items":[],"per_speaker_highlights":[]}"#),
            Self.answer(Self.completeAnswer),
        ])
        #expect(run.ending == Self.completeEnding)
        try #require(run.calls.count == 2)
        try #require(run.calls[1].messages.count == 4)
        #expect(run.calls[1].messages[3].content == "Your previous answer is missing: tldr. Return the complete JSON object with every key — no prose, no markdown fences.")
    }

    /// `null` is not a value: a part sent as null is as missing as an absent one
    /// (it decodes to no overview, or no action items, all the same).
    @Test func nullPartsCountAsMissing() async throws {
        let run = await Self.run([
            Self.answer(#"{"tldr":"t","overview":null,"action_items":null,"per_speaker_highlights":[]}"#),
            Self.answer(Self.completeAnswer),
        ])
        #expect(run.ending == Self.completeEnding)
        try #require(run.calls.count == 2)
        try #require(run.calls[1].messages.count == 4)
        #expect(run.calls[1].messages[3].content == "Your previous answer is missing: overview, action_items. Return the complete JSON object with every key — no prose, no markdown fences.")
    }

    // MARK: - After the retry

    @Test func persistentMissingPartsThrowIncomplete() async {
        let partial = Self.answer(#"{"tldr":"t","action_items":[],"per_speaker_highlights":[]}"#)
        let run = await Self.run([partial, partial])
        #expect(run.ending == .incomplete(missing: ["overview"]))
        #expect(run.calls.count == 2)
    }

    @Test func persistentMissingTLDRThrowsIncomplete() async {
        let drifted = Self.answer(#"{"summary":"s","overview":"o","action_items":[],"per_speaker_highlights":[]}"#)
        let run = await Self.run([drifted, drifted])
        #expect(run.ending == .incomplete(missing: ["tldr"]))
        #expect(run.calls.count == 2)
    }

    @Test func persistentCutOffThrowsTruncated() async {
        let cutOff = Self.answer(#"{"tldr":"a""#, finish: "length")
        let run = await Self.run([cutOff, cutOff])
        #expect(run.ending == .truncated)
        #expect(run.calls.count == 2)
    }

    @Test func emptyTwiceThrowsEmptyAnswer() async {
        let empty = Self.answer("", finish: "stop")
        let run = await Self.run([empty, empty])
        #expect(run.ending == .invalidJSON(snippet: ""))
        #expect(run.message == "The model returned an empty answer.")
        #expect(run.calls.count == 2)
    }

    /// A provider that refuses the doubled budget (it is above the model's
    /// output limit) answers 400 or 404: the summary still didn't fit, so the
    /// run ends `.truncated`. A 500, or a 400 on a retry that didn't raise the
    /// budget, stays the HTTP error it was.
    @Test func rejectedBiggerRetryThrowsTruncated() async {
        let cutOff = Self.answer(#"{"tldr":"a""#, finish: "length")
        let table: [(first: Result<ChatCompletion, any Error>, retryStatus: Int, want: Ending)] = [
            (cutOff, 400, .truncated),
            (cutOff, 404, .truncated),
            (cutOff, 500, .httpError(status: 500)),
            (Self.answer("", finish: "stop"), 400, .httpError(status: 400)),
        ]
        for (first, status, want) in table {
            let refused: Result<ChatCompletion, any Error> =
                .failure(OpenRouterError.httpError(status: status, bodySnippet: "max_tokens too large"))
            let run = await Self.run([first, refused])
            #expect(run.ending == want, "retry answered HTTP \(status)")
            #expect(run.calls.count == 2)
        }
    }

    // MARK: - Budget

    /// A caller-set budget is what the first request asks for; a cut-off retry doubles it.
    @Test func customBudgetIsSentAndDoubled() async throws {
        let run = await Self.run(
            [Self.answer(#"{"tldr":"a""#, finish: "length"), Self.answer(Self.completeAnswer)],
            maxOutputTokens: 300
        )
        try #require(run.calls.count == 2)
        #expect(run.calls[0].maxTokens == 300)
        #expect(run.calls[1].maxTokens == 600)
    }

    /// The budget is clamped to 1…1,000,000, at init and on every later write
    /// (the CLI sets it after building the summarizer): the cut-off retry's
    /// doubling can't overflow, and a nonsense budget never reaches a provider.
    @Test func budgetIsClamped() async throws {
        let cutOffThenComplete = [Self.answer(#"{"tldr":"a""#, finish: "length"), Self.answer(Self.completeAnswer)]
        let table: [(asked: Int, first: Int, retry: Int)] = [(0, 1, 2), (Int.max, 1_000_000, 2_000_000)]
        for (asked, first, retry) in table {
            var summarizer = Summarizer(client: MockChatClient(results: cutOffThenComplete), model: "m")
            summarizer.maxOutputTokens = asked
            #expect(summarizer.maxOutputTokens == first, "set to \(asked)")

            let run = await Self.run(cutOffThenComplete, maxOutputTokens: asked)
            try #require(run.calls.count == 2)
            #expect(run.calls[0].maxTokens == first, "asked for \(asked)")
            #expect(run.calls[1].maxTokens == retry, "asked for \(asked)")
        }
    }

    // MARK: - Assessment

    @Test func unterminatedJSONTable() {
        let table: [(text: String, unterminated: Bool)] = [
            (#"{"a":"b"#, true),                                       // inside a string
            (#"{"a":["x""#, true),                                     // inside an array
            (#"{"a":"b\""#, true),                                     // an escaped quote keeps the string open
            (#"{"a":"b\"}""#, true),                                   // …so the brace after it doesn't close
            ("```json\n{\"tldr\":\"a\",\"overview\":\"b", true),       // fenced partial, no closing fence
            (#"{"a":"b"}"#, false),
            ("{}", false),
            (#"{"a":1} tail"#, false),                                 // closed, then text: malformed, not cut off
            ("Sure! {", false),                                        // not a JSON object
            ("", false),
            (#"{"a":"}"}"#, false),                                    // a brace inside a string doesn't close
        ]
        for (text, unterminated) in table {
            #expect(Summarizer.isUnterminatedJSONObject(text) == unterminated, "\(text)")
        }
    }

    /// `assess` reduced to a comparable label.
    static func label(_ assessment: Summarizer.Assessment) -> String {
        switch assessment {
        case .complete: return "complete"
        case let .cutOff(hadText): return hadText ? "cutOff(text)" : "cutOff(no text)"
        case .empty: return "empty"
        case let .incomplete(missing): return "incomplete(\(missing.joined(separator: ", ")))"
        case .malformed: return "malformed"
        }
    }

    /// Spec §3.1, one row per kind of answer. The finish reason and the text's
    /// shape are separate cut-off signals, and fences are stripped first.
    @Test func assessClassifiesEachKindOfAnswer() {
        let table: [(content: String, finish: String?, want: String)] = [
            (Self.completeAnswer, "stop", "complete"),
            ("```json\n\(Self.completeAnswer)\n```", nil, "complete"),
            (Self.completeAnswer, "length", "cutOff(text)"),          // "length" alone is a cut-off
            (#"{"tldr":"a","overview":"b"#, "stop", "cutOff(text)"),   // so is the shape alone
            ("", "length", "cutOff(no text)"),
            (" \n", "length", "cutOff(no text)"),
            ("", "stop", "empty"),
            (#"{"tldr":"t"}"#, "stop", "incomplete(overview, action_items, per_speaker_highlights)"),
            (#"{"tldr":5,"overview":"o","action_items":[],"per_speaker_highlights":[]}"#, "stop",
             "incomplete(tldr)"),                                      // a TL;DR must be a string
            (#"{"tldr":"t","overview":5,"action_items":[],"per_speaker_highlights":[]}"#, "stop",
             "malformed"),                                             // every part there, one won't decode
            ("Sure! Here is the summary.", "stop", "malformed"),
            ("[1, 2]", "stop", "malformed"),                           // JSON, but not an object
            (#""just a string""#, "stop", "malformed"),
        ]
        for (content, finish, want) in table {
            let assessment = Summarizer.assess(ChatCompletion(content: content, finishReason: finish))
            #expect(Self.label(assessment) == want, "\(content) + \(finish ?? "nil")")
        }
    }

    // MARK: - Messages

    /// What the user reads on the meeting's error card and in the popover.
    @Test func errorCopy() {
        #expect(SummarizerError.truncated.localizedDescription.contains("cut off"))
        #expect(SummarizerError.incomplete(missing: ["overview", "action_items"]).localizedDescription
            .contains("(no overview, action items)"))
        #expect(SummarizerError.invalidJSON(snippet: "").localizedDescription == "The model returned an empty answer.")
        #expect(SummarizerError.invalidJSON(snippet: "x").localizedDescription
            .hasPrefix("The model did not return a complete summary. Got: x"))
    }

    // MARK: - Lock

    /// Lock: the rule must not over-reject. Lists may be empty, the overview
    /// blank (a ten-second recording), and the keys camelCase — the decoder
    /// reads both spellings. Accepted on the first call.
    @Test func completeAnswerWithEmptyPartsIsAcceptedFirstTime() async {
        let run = await Self.run([
            Self.answer(#"{"tldr":"t","overview":"","actionItems":[],"perSpeakerHighlights":[]}"#),
        ])
        #expect(run.ending == .summary(title: nil, tldr: "t"))
        #expect(run.calls.count == 1)
    }
}
