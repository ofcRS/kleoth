import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A single chat message in an OpenRouter completion request.
public struct ChatMessage: Codable, Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// Errors thrown by ``OpenRouterClient``.
public enum OpenRouterError: Error, Sendable {
    /// The server returned a non-2xx status. Carries the status code and a
    /// truncated snippet of the response body for diagnostics.
    case httpError(status: Int, bodySnippet: String)
    /// The response was 2xx but contained no choices / message content.
    case noContent
}

extension OpenRouterError: LocalizedError {
    // A readable message for the user-facing `summaryError` line — the default
    // `localizedDescription` of a bare enum is an opaque "error 1" string.
    public var errorDescription: String? {
        switch self {
        case let .httpError(status, bodySnippet):
            return "OpenRouter returned HTTP \(status): \(bodySnippet)"
        case .noContent:
            return "OpenRouter returned an empty response."
        }
    }
}

/// How OpenRouter should constrain the response shape.
public enum OpenRouterResponseFormat: Sendable {
    /// No `response_format` constraint.
    case none
    /// `response_format: {type: "json_object"}` — valid JSON, free shape.
    case jsonObject
    /// `response_format: {type: "json_schema", …}` with a strict schema.
    /// `schemaJSON` is a raw JSON-schema document (parsed via
    /// `JSONSerialization` so it embeds cleanly into the request body).
    case jsonSchema(name: String, schemaJSON: String)

    /// Whether this is the strict `.jsonSchema` case (used to gate the
    /// fallback retry).
    var isJSONSchema: Bool {
        if case .jsonSchema = self { return true }
        return false
    }
}

/// OpenRouter's unified `reasoning` request parameter (`{"reasoning": {…}}`),
/// which caps how much a reasoning model thinks before answering.
///
/// Measured on `z-ai/glm-5.3-flash` (the default polish model) on 2026-09-03
/// against the verbatim dictation prompt + a Russian sample: without the
/// parameter the model spent 104–362 reasoning tokens per polish and took
/// 4.9–14.2 s (mean 8.4 s — over the 8 s dictation budget in one of three
/// runs); `effort: "low"` produced 0 reasoning tokens, 2.3–4.9 s (mean 3.4 s),
/// with identical, correct output. `{"enabled": false}` is rejected by that
/// endpoint with 400 "Reasoning is mandatory", and `{"exclude": true}` only
/// hides the reasoning (155–272 tokens, 6.7–9.4 s). Only the dictation path
/// sends this; `Summarizer` never does, so its body is unchanged.
public struct OpenRouterReasoning: Sendable, Equatable {
    /// OpenRouter's normalized effort levels.
    public enum Effort: String, Sendable {
        case minimal, low, medium, high
    }

    public var effort: Effort
    /// When true, OpenRouter strips the reasoning tokens from the response
    /// (they are still generated and billed).
    public var exclude: Bool

    public init(effort: Effort, exclude: Bool = false) {
        self.effort = effort
        self.exclude = exclude
    }

    /// The setting the dictation polisher uses.
    public static let low = OpenRouterReasoning(effort: .low)

    /// The JSON object written under the `reasoning` key.
    var bodyValue: [String: Any] {
        var value: [String: Any] = ["effort": effort.rawValue]
        if exclude { value["exclude"] = true }
        return value
    }
}

/// OpenRouter = the OpenAI-compatible client pointed at openrouter.ai with the
/// `provider.require_parameters` routing key and attribution headers.
///
/// `Sendable` is explicit (a public struct gets no implicit conformance):
/// every stored property is a value or a `Sendable` existential (`HTTPTransport`
/// refines `Sendable`). Dictation needs it — `DictationPolisher: Sendable` and
/// capturing a client inside `withTimeout`'s `@Sendable` closure both depend on
/// it. Mirrors how `ScribeClient` is `Sendable` via `Transcriber`.
public struct OpenRouterClient: ChatCompleting {
    public let apiKey: String
    public let transport: HTTPTransport
    private let inner: OpenAICompatibleClient

    public static let baseURL = URL(string: "https://openrouter.ai/api/v1")!

    public init(apiKey: String, transport: HTTPTransport) {
        self.apiKey = apiKey
        self.transport = transport
        self.inner = OpenAICompatibleClient(
            baseURL: Self.baseURL, apiKey: apiKey, transport: transport, sendsOpenRouterProviderKey: true)
    }

    /// Requests a chat completion and returns the message content plus
    /// optional usage metadata. See ``OpenAICompatibleClient/complete(messages:model:responseFormat:maxTokens:temperature:reasoning:)``
    /// for the parameter contract, response decoding and the fallback-retry behavior.
    public func complete(
        messages: [ChatMessage],
        model: String,
        responseFormat: OpenRouterResponseFormat,
        maxTokens: Int,
        temperature: Double? = nil,
        reasoning: OpenRouterReasoning? = nil
    ) async throws -> ChatCompletion {
        try await inner.complete(
            messages: messages, model: model, responseFormat: responseFormat,
            maxTokens: maxTokens, temperature: temperature, reasoning: reasoning
        )
    }
}
