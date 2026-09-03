import Testing
import Foundation
@testable import KleothCore

/// Guards the one risk of adding `temperature:` to `OpenRouterClient`: that the
/// summarization request body silently changed. `Summarizer` never passes a
/// temperature, so its body must stay exactly what it was.
@Suite struct OpenRouterTemperatureTests {
    static let summaryJSON = """
    {
      "tldr": "Shipped the beta.",
      "overview": "The team shipped the beta.",
      "action_items": [],
      "per_speaker_highlights": []
    }
    """

    static func envelope(_ content: String) -> String {
        var escaped = ""
        for scalar in content.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "{ \"choices\": [ { \"message\": { \"role\": \"assistant\", \"content\": \"\(escaped)\" }, \"finish_reason\": \"stop\" } ] }"
    }

    static func transcript() -> Transcript {
        Transcript(
            utterances: [
                Utterance(speakerId: "speaker_0", speakerName: "Alice", start: 0, end: 1, text: "Let's ship."),
            ],
            languageCode: "en",
            durationSecs: 1
        )
    }

    static func metadata() -> MeetingMetadata {
        MeetingMetadata(title: "Launch", date: "2026-09-03", participants: ["Alice"])
    }

    /// Runs a summarization and returns the exact bytes that went on the wire.
    static func summarizerRequestBody() async throws -> Data {
        let transport = MockTransport(json: envelope(summaryJSON))
        let summarizer = Summarizer(client: OpenRouterClient(apiKey: "test-key", transport: transport))
        _ = try await summarizer.summarize(transcript: transcript(), metadata: metadata())
        return try #require(transport.recordedRequests.first?.httpBody)
    }

    @Test func summarizerRequestBodyIsByteIdenticalWithoutTemperature() async throws {
        // NOTE: `makeBody` serializes a Swift `[String: Any]`, whose key order is
        // randomized per dictionary instance, so two runs are *semantically*
        // identical but not literally byte-equal. Identity is therefore asserted
        // on the parsed object (order-independent `NSDictionary` equality) plus
        // the exact top-level key set — which is what "the body did not change"
        // actually means on the wire.
        let first = try await Self.summarizerRequestBody()
        let second = try await Self.summarizerRequestBody()
        let firstObject = try #require(try JSONSerialization.jsonObject(with: first) as? NSDictionary)
        let secondObject = try #require(try JSONSerialization.jsonObject(with: second) as? NSDictionary)
        #expect(firstObject == secondObject)

        // Exactly the pre-temperature key set — no `temperature`, no `reasoning`.
        let body = try #require(firstObject as? [String: Any])
        #expect(Set(body.keys) == ["model", "messages", "max_tokens", "provider", "response_format"])
        #expect(body["temperature"] == nil)
        #expect(body["reasoning"] == nil)

        // Explicitly passing nil produces the same request as omitting the parameter.
        let omittedTransport = MockTransport(json: Self.envelope(#"{"ok":true}"#))
        let explicitNilTransport = MockTransport(json: Self.envelope(#"{"ok":true}"#))
        let messages = [ChatMessage(role: "user", content: "hi")]
        _ = try await OpenRouterClient(apiKey: "k", transport: omittedTransport)
            .complete(messages: messages, model: "m", responseFormat: .jsonObject, maxTokens: 16)
        _ = try await OpenRouterClient(apiKey: "k", transport: explicitNilTransport)
            .complete(messages: messages, model: "m", responseFormat: .jsonObject, maxTokens: 16, temperature: nil)

        let omittedBody = try #require(omittedTransport.recordedRequests.first?.httpBody)
        let explicitNilBody = try #require(explicitNilTransport.recordedRequests.first?.httpBody)
        let omittedObject = try #require(try JSONSerialization.jsonObject(with: omittedBody) as? NSDictionary)
        let explicitNilObject = try #require(try JSONSerialization.jsonObject(with: explicitNilBody) as? NSDictionary)
        #expect(omittedObject == explicitNilObject)
        #expect((omittedObject as? [String: Any])?["temperature"] == nil)
        #expect((omittedObject as? [String: Any])?["reasoning"] == nil)
    }

    @Test func reasoningIsEncodedOnlyWhenProvided() async throws {
        let transport = MockTransport(json: Self.envelope(#"{"ok":true}"#))
        _ = try await OpenRouterClient(apiKey: "k", transport: transport).complete(
            messages: [ChatMessage(role: "user", content: "hi")],
            model: "z-ai/glm-5.3-flash",
            responseFormat: .jsonObject,
            maxTokens: 32,
            reasoning: .low
        )
        let data = try #require(transport.recordedRequests.first?.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let reasoning = try #require(body["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "low")
        // `exclude` is only written when set — the default object is exactly `{effort}`.
        #expect(reasoning["exclude"] == nil)
        #expect(reasoning.count == 1)

        let excluded = OpenRouterReasoning(effort: .minimal, exclude: true).bodyValue
        #expect(excluded["effort"] as? String == "minimal")
        #expect(excluded["exclude"] as? Bool == true)
    }

    @Test func temperatureIsEncodedWhenProvided() async throws {
        let transport = MockTransport(json: Self.envelope(#"{"ok":true}"#))
        _ = try await OpenRouterClient(apiKey: "k", transport: transport).complete(
            messages: [ChatMessage(role: "user", content: "hi")],
            model: "google/gemini-3.8-flash",
            responseFormat: .jsonObject,
            maxTokens: 32,
            temperature: 0.2
        )

        let data = try #require(transport.recordedRequests.first?.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["temperature"] as? Double == 0.2)
        #expect(body["max_tokens"] as? Int == 32)
    }

    @Test func relaxedRetryFiresForTemperatureOnJSONObject() async throws {
        // A 404 on a body that was already `json_object` still retries when
        // there is a parameter left to drop — the retry is about routing
        // parameters, not only the strict schema.
        let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        let transport = MockTransport(outcomes: [
            .success(Data("{\"error\":\"no endpoints\"}".utf8), MockTransport.httpResponse(url: url, statusCode: 404)),
            .success(Data(Self.envelope(#"{"ok":true}"#).utf8), MockTransport.httpResponse(url: url, statusCode: 200)),
        ])
        let result = try await OpenRouterClient(apiKey: "k", transport: transport).complete(
            messages: [ChatMessage(role: "user", content: "hi")],
            model: "google/gemini-3.8-flash",
            responseFormat: .jsonObject,
            maxTokens: 32,
            temperature: 0.2,
            reasoning: .low
        )
        #expect(result.content == #"{"ok":true}"#)
        #expect(transport.callCount == 2)

        let firstData = try #require(transport.recordedRequests[0].httpBody)
        let first = try #require(try JSONSerialization.jsonObject(with: firstData) as? [String: Any])
        #expect(first["temperature"] as? Double == 0.2)
        #expect(first["reasoning"] != nil)
        let secondData = try #require(transport.recordedRequests[1].httpBody)
        let second = try #require(try JSONSerialization.jsonObject(with: secondData) as? [String: Any])
        #expect(second["temperature"] == nil)
        #expect(second["reasoning"] == nil)
        // The format is left alone — it was not the strict schema.
        #expect((second["response_format"] as? [String: Any])?["type"] as? String == "json_object")
    }

    @Test func noRetryWhenNothingIsLeftToRelax() async throws {
        // `.jsonObject` with no temperature/reasoning: the retry body would be
        // identical, so a 404 is surfaced after ONE call.
        let transport = MockTransport(json: "{\"error\":\"no endpoints\"}", statusCode: 404)
        await #expect(throws: OpenRouterError.self) {
            _ = try await OpenRouterClient(apiKey: "k", transport: transport).complete(
                messages: [ChatMessage(role: "user", content: "hi")],
                model: "m",
                responseFormat: .jsonObject,
                maxTokens: 32
            )
        }
        #expect(transport.callCount == 1)

        // A 500 never retries, even with everything to drop.
        let serverError = MockTransport(json: "{\"error\":\"boom\"}", statusCode: 500)
        await #expect(throws: OpenRouterError.self) {
            _ = try await OpenRouterClient(apiKey: "k", transport: serverError).complete(
                messages: [ChatMessage(role: "user", content: "hi")],
                model: "m",
                responseFormat: .jsonSchema(name: "t", schemaJSON: "{\"type\":\"object\"}"),
                maxTokens: 32,
                temperature: 0.2
            )
        }
        #expect(serverError.callCount == 1)
    }

    @Test func openRouterClientIsSendable() {
        let client = OpenRouterClient(apiKey: "k", transport: MockTransport(json: "{}"))
        // Compile-time proof of the conformance `DictationPolisher: Sendable`
        // depends on. If `: Sendable` is dropped from the type, this stops building.
        let _: any Sendable = client
        #expect(client.apiKey == "k")
    }
}
