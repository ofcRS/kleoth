import Testing
import Foundation
@testable import KleothCore

@Suite struct OpenAICompatibleClientTests {
    static let okEnvelope = #"{ "choices": [ { "message": { "role": "assistant", "content": "hi" }, "finish_reason": "stop" } ], "usage": { "prompt_tokens": 3, "completion_tokens": 1 } }"#

    static func body(of transport: MockTransport, at index: Int = 0) throws -> [String: Any] {
        let data = try #require(transport.recordedRequests[index].httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func localServerGetsNoProviderKeyAndNoAuthorization() async throws {
        let transport = MockTransport(json: Self.okEnvelope)
        let client = OpenAICompatibleClient(
            baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: nil, transport: transport)
        let completion = try await client.complete(
            messages: [ChatMessage(role: "user", content: "x")], model: "llama3",
            responseFormat: .jsonObject, maxTokens: 10)
        #expect(completion.content == "hi")
        #expect(completion.usage?.promptTokens == 3)
        #expect(completion.usage?.cost == nil)
        let request = transport.recordedRequests[0]
        #expect(request.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try Self.body(of: transport)
        #expect(body["provider"] == nil)
        #expect(body["model"] as? String == "llama3")
    }

    @Test func keyBecomesBearerHeader() async throws {
        let transport = MockTransport(json: Self.okEnvelope)
        let client = OpenAICompatibleClient(
            baseURL: URL(string: "http://localhost:1234/v1")!, apiKey: "test-key", transport: transport)
        _ = try await client.complete(messages: [ChatMessage(role: "user", content: "x")], model: "m",
                                      responseFormat: .none, maxTokens: 10)
        #expect(transport.recordedRequests[0].value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }

    @Test func openRouterWrapperStillSendsProviderKeyAndAttribution() async throws {
        let transport = MockTransport(json: Self.okEnvelope)
        let client = OpenRouterClient(apiKey: "test-key", transport: transport)
        _ = try await client.complete(messages: [ChatMessage(role: "user", content: "x")], model: "m",
                                      responseFormat: .none, maxTokens: 10)
        let request = transport.recordedRequests[0]
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "X-Title") == "Kleoth")
        let body = try Self.body(of: transport)
        let provider = try #require(body["provider"] as? [String: Any])
        #expect(provider["require_parameters"] as? Bool == true)
    }

    @Test func ollamaMissingModelBecomesModelMissing() async throws {
        let transport = MockTransport(
            json: #"{"error":{"message":"model \"llama9\" not found, try pulling it first","type":"api_error"}}"#,
            statusCode: 404)
        let client = OpenAICompatibleClient(
            baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: nil, transport: transport)
        await #expect(throws: ProviderError.modelMissing(model: "llama9", hint: "ollama pull llama9")) {
            _ = try await client.complete(messages: [ChatMessage(role: "user", content: "x")], model: "llama9",
                                          responseFormat: .jsonObject, maxTokens: 10)
        }
        // A missing model is not a routing problem: no relaxed retry.
        #expect(transport.callCount == 1)
    }

    /// The `ollama pull` rewrite is local-server-only. OpenRouter answers 404
    /// for its own reasons (a data-policy guardrail, a ZDR violation) and those
    /// bodies can contain the same words, so an OpenRouter 404 must still fall
    /// into the relaxed retry instead of aborting with a pull hint.
    @Test func openRouter404KeepsTheRelaxedRetryInsteadOfAPullHint() async throws {
        let transport = MockTransport(outcomes: [
            .success(Data(#"{"error":{"message":"No endpoints found — model not found, try pull"}}"#.utf8),
                     MockTransport.httpResponse(url: URL(string: "http://x")!, statusCode: 404)),
            .success(Data(Self.okEnvelope.utf8),
                     MockTransport.httpResponse(url: URL(string: "http://x")!, statusCode: 200)),
        ])
        let client = OpenRouterClient(apiKey: "test-key", transport: transport)
        let completion = try await client.complete(
            messages: [ChatMessage(role: "user", content: "x")], model: "some/model",
            responseFormat: .jsonSchema(name: "s", schemaJSON: #"{"type":"object"}"#), maxTokens: 10)
        #expect(completion.content == "hi")
        #expect(transport.callCount == 2)
    }

    @Test func schemaRejectionStillRetriesAsJSONObject() async throws {
        let transport = MockTransport(outcomes: [
            .success(Data(#"{"error":"unsupported response_format"}"#.utf8),
                     MockTransport.httpResponse(url: URL(string: "http://x")!, statusCode: 400)),
            .success(Data(Self.okEnvelope.utf8),
                     MockTransport.httpResponse(url: URL(string: "http://x")!, statusCode: 200)),
        ])
        let client = OpenAICompatibleClient(
            baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: nil, transport: transport)
        let completion = try await client.complete(
            messages: [ChatMessage(role: "user", content: "x")], model: "m",
            responseFormat: .jsonSchema(name: "s", schemaJSON: #"{"type":"object"}"#), maxTokens: 10)
        #expect(completion.content == "hi")
        #expect(transport.callCount == 2)
        let second = try Self.body(of: transport, at: 1)
        let format = try #require(second["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_object")
    }

    @Test func providerErrorMessagesAreReadable() {
        #expect(ProviderError.notSignedIn(tool: "Claude Code").errorDescription
                == "Claude Code is not signed in. Open a terminal, run `claude`, and sign in.")
        #expect(ProviderError.unreachable(url: URL(string: "http://localhost:11434/v1")!).errorDescription
                == "No server at http://localhost:11434 — is Ollama running?")
        #expect(ProviderError.noProvider.errorDescription
                == "No AI provider available — open Settings → Accounts.")
    }
}
