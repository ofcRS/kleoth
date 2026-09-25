import Foundation
import Testing
@testable import KleothCore

/// The scene step (design doc 2026-09-24 §3.3): one chat call that turns a
/// meeting's title, TL;DR and the start of its overview into
/// `{sensitive, style, scene}` — never from the transcript, action items or
/// speakers.
@Suite struct CoverSceneWriterTests {
    private let summary = MeetingSummary(
        title: "Q3 planning",
        tldr: "We set the roadmap.",
        overview: String(repeating: "o", count: 2_000),
        actionItems: [ActionItem(owner: "Anna", task: "Ship it")],
        perSpeakerHighlights: [SpeakerHighlight(speaker: "Boris", highlights: ["Wants tests"])]
    )
    private let good = #"{"sensitive":false,"style":"sketch","scene":"Two otters stack smooth pebbles into a little tower on a riverbank."}"#

    /// Matches any `CoverError.sceneUnreadable`, whatever its log detail.
    private func expectUnreadable(
        _ content: String, fixedStyle: CoverStyle? = nil, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let error = #expect(throws: CoverError.self, sourceLocation: sourceLocation) {
            _ = try CoverSceneWriter.parse(content, fixedStyle: fixedStyle)
        }
        guard case .sceneUnreadable = error else {
            Issue.record("expected sceneUnreadable, got \(String(describing: error))", sourceLocation: sourceLocation)
            return
        }
    }

    @Test func requestShapeIsSchemaLowReasoningNoTemperature() async throws {
        let client = MockChatClient(results: [.success(ChatCompletion(content: good))])
        let writer = CoverSceneWriter(client: client, model: "m")

        _ = try await writer.write(title: "T", summary: summary, fixedStyle: nil, previousScene: nil)

        #expect(client.calls.count == 1)
        let call = try #require(client.calls.first)
        guard case let .jsonSchema(name, schemaJSON) = call.responseFormat else {
            Issue.record("expected a strict json_schema response format")
            return
        }
        #expect(name == "cover_scene")
        let schema = try #require(
            try JSONSerialization.jsonObject(with: Data(schemaJSON.utf8)) as? [String: Any]
        )
        #expect(schema["required"] as? [String] == ["sensitive", "style", "scene"])
        let properties = try #require(schema["properties"] as? [String: Any])
        let style = try #require(properties["style"] as? [String: Any])
        #expect(style["enum"] as? [String] == ["animation", "illustration", "sketch", "clay"])
        #expect(call.maxTokens == 1_000)
        #expect(call.temperature == nil)
        #expect(call.reasoning == .low)
        #expect(call.messages[0].role == "system")
        #expect(call.messages[0].content == CoverSceneWriter.systemPrompt)
        #expect(call.model == "m")
    }

    /// OpenRouter turns `low` into a 1,024-token thinking budget, which is not
    /// below the 1,000-token cap, so a budget-style Anthropic model rejects the
    /// request; the scene goes without reasoning instead.
    @Test func anthropicModelSendsNoReasoning() async throws {
        let client = MockChatClient(results: [.success(ChatCompletion(content: good))])
        let writer = CoverSceneWriter(client: client, model: "anthropic/claude-haiku-4.5")

        _ = try await writer.write(title: "T", summary: summary, fixedStyle: nil, previousScene: nil)

        let call = try #require(client.calls.first)
        #expect(call.reasoning == nil)
        #expect(call.maxTokens == 1_000)
        #expect(call.temperature == nil)
        guard case .jsonSchema(name: "cover_scene", schemaJSON: _) = call.responseFormat else {
            Issue.record("expected the strict cover_scene schema")
            return
        }
    }

    /// An answer cut off by the output cap says so in the log detail; the
    /// error case is the same.
    @Test func truncatedAnswerIsNamedInTheUnreadableDetail() async throws {
        let cut = #"{"sensitive":false,"style":"sketch","scene":"Two otters stack"#
        for (finishReason, prefixed) in [("length", true), ("stop", false)] {
            let client = MockChatClient(results: [.success(ChatCompletion(content: cut, finishReason: finishReason))])
            let writer = CoverSceneWriter(client: client, model: "m")
            do {
                _ = try await writer.write(title: "T", summary: summary, fixedStyle: nil, previousScene: nil)
                Issue.record("expected sceneUnreadable for finish_reason \(finishReason)")
            } catch let CoverError.sceneUnreadable(detail) {
                #expect(detail.hasPrefix("cut off (length): ") == prefixed, "detail: \(detail)")
                #expect(detail.contains("Two otters stack"))
            }
        }
    }

    @Test func userContentHasTitleTLDRAndAtMost1500OverviewCharactersAndNothingElse() {
        let content = CoverSceneWriter.userContent(
            title: "Q3 planning", summary: summary, fixedStyle: nil, previousScene: nil
        )

        #expect(content.contains("Q3 planning"))
        #expect(content.contains("We set the roadmap."))
        #expect(content.filter { $0 == "o" }.count >= 1_500)
        #expect(content.range(of: String(repeating: "o", count: 1_501)) == nil)
        for outsideTheInput in ["Anna", "Ship it", "Boris", "Wants tests"] {
            #expect(!content.contains(outsideTheInput), "user content leaks \(outsideTheInput)")
        }
    }

    @Test func previousSceneAndFixedStyleAppearWhenGiven() {
        let given = CoverSceneWriter.userContent(
            title: "T", summary: summary, fixedStyle: .clay, previousScene: "an owl reads"
        )
        #expect(given.contains("an owl reads"))
        #expect(given.contains("clearly different"))
        #expect(given.contains("clay"))

        let neither = CoverSceneWriter.userContent(title: "T", summary: summary, fixedStyle: nil, previousScene: nil)
        #expect(!neither.contains("Previous"))
        #expect(!neither.contains("Style:"))
    }

    @Test func sensitiveAnswerHasAnEmptyScene() throws {
        let scene = try CoverSceneWriter.parse(
            #"{"sensitive":true,"style":"illustration","scene":"a nurse"}"#, fixedStyle: nil
        )

        #expect(scene == CoverScene(sensitive: true, style: .illustration, scene: ""))
    }

    @Test func badStyleFallsBackToFixedOrIllustration() throws {
        let oil = #"{"sensitive":false,"style":"oil","scene":"an otter naps"}"#
        #expect(try CoverSceneWriter.parse(oil, fixedStyle: .sketch).style == .sketch)
        #expect(try CoverSceneWriter.parse(oil, fixedStyle: nil).style == .illustration)

        // A fixed style wins over a valid pick.
        let clay = #"{"sensitive":false,"style":"clay","scene":"an otter naps"}"#
        #expect(try CoverSceneWriter.parse(clay, fixedStyle: .sketch).style == .sketch)

        let missing = #"{"sensitive":false,"scene":"an otter naps"}"#
        #expect(try CoverSceneWriter.parse(missing, fixedStyle: nil).style == .illustration)
    }

    @Test func missingSensitiveOrEmptySceneIsUnreadable() {
        expectUnreadable(#"{"style":"clay","scene":"x"}"#)
        expectUnreadable(#"{"sensitive":false,"style":"clay","scene":"  "}"#)
        expectUnreadable("not json")
    }

    @Test func fencedJSONIsAccepted() throws {
        let scene = try CoverSceneWriter.parse("```json\n" + good + "\n```", fixedStyle: nil)

        #expect(scene == CoverScene(
            sensitive: false, style: .sketch,
            scene: "Two otters stack smooth pebbles into a little tower on a riverbank."
        ))
    }

    @Test func sanitizeStripsQuotesDigitsAndCaps() {
        #expect(CoverSceneWriter.sanitize("An \"owl\" reads 3 'books'  under   7 lamps") == "An owl reads books under lamps")
        #expect(CoverSceneWriter.sanitize(String(repeating: "a", count: 600)).count == 400)
        // A capped scene ends on a whole word: cut at the last space at or before the cap.
        let capped = CoverSceneWriter.sanitize(String(repeating: "otter ", count: 100))
        #expect(capped.count <= 400)
        #expect(!capped.hasSuffix(" "))
        #expect(capped.split(separator: " ").allSatisfy { $0 == "otter" }, "half a word in \(capped)")
        let russian = CoverSceneWriter.sanitize("«так» — “да”")
        #expect(!russian.contains { "«»“”".contains($0) }, "quotes left in \(russian)")
    }

    @Test func costIsUsageCost() async throws {
        let paid = MockChatClient(results: [.success(ChatCompletion(content: good, usage: ChatUsage(cost: 0.0002)))])
        let paidResult = try await CoverSceneWriter(client: paid, model: "m")
            .write(title: "T", summary: summary, fixedStyle: nil, previousScene: nil)
        #expect(paidResult.cost == 0.0002)

        let free = MockChatClient(results: [.success(ChatCompletion(content: good, usage: nil))])
        let freeResult = try await CoverSceneWriter(client: free, model: "m")
            .write(title: "T", summary: summary, fixedStyle: nil, previousScene: nil)
        #expect(freeResult.cost == 0)
    }
}
