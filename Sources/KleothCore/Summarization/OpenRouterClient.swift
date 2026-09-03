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

/// Usage / cost metadata returned by OpenRouter.
///
/// `cost` is the USD cost already computed by OpenRouter.
public struct OpenRouterUsage: Codable, Sendable {
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let cost: Double?

    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, cost: Double? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cost = cost
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

/// Client for the OpenRouter chat completions endpoint.
///
/// POST `https://openrouter.ai/api/v1/chat/completions`, authenticated with
/// `Authorization: Bearer <key>`.
///
/// `Sendable` is explicit (a public struct gets no implicit conformance):
/// every stored property is a value or a `Sendable` existential (`HTTPTransport`
/// refines `Sendable`). Dictation needs it — `DictationPolisher: Sendable` and
/// capturing a client inside `withTimeout`'s `@Sendable` closure both depend on
/// it. Mirrors how `ScribeClient` is `Sendable` via `Transcriber`.
public struct OpenRouterClient: Sendable {
    public let apiKey: String
    public let transport: HTTPTransport

    public init(apiKey: String, transport: HTTPTransport) {
        self.apiKey = apiKey
        self.transport = transport
    }

    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    // MARK: - Response body

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let role: String?
                let content: String?
            }
            let message: Message?
            /// Why generation stopped — `"stop"` (complete), `"length"`
            /// (truncated: hit the output cap, often after a reasoning model
            /// spent the budget thinking), `"content_filter"`, etc. Decoded so
            /// the summarizer can distinguish a complete short answer from a
            /// silently truncated one. (`convertFromSnakeCase` maps `finish_reason`.)
            let finishReason: String?
        }
        let choices: [Choice]?
        let usage: OpenRouterUsage?
    }

    /// Requests a chat completion and returns the message content plus
    /// optional usage metadata.
    ///
    /// - Parameter responseFormat: how the response shape is constrained
    ///   (none / `json_object` / strict `json_schema`).
    /// - Parameter temperature: sampling temperature. Omitted from the request
    ///   body entirely when `nil` (the default), so callers that never set it —
    ///   `Summarizer` — send a byte-identical body to before this parameter existed.
    /// - Parameter reasoning: OpenRouter's `reasoning` object (see
    ///   ``OpenRouterReasoning``). Omitted from the body when `nil` (the
    ///   default) — again so `Summarizer`'s body is unchanged. Kept on the
    ///   `.jsonObject` fallback retry, like `temperature` (it is not a
    ///   schema-support symptom).
    ///
    /// When `responseFormat` is `.jsonSchema` and the request fails with HTTP
    /// 400 or 404 — the symptoms of a provider that doesn't support strict JSON
    /// schemas, including this account's no-train providers under
    /// `require_parameters: true` — it transparently retries once with
    /// `.jsonObject` so summarization still succeeds.
    public func complete(
        messages: [ChatMessage],
        model: String,
        responseFormat: OpenRouterResponseFormat,
        maxTokens: Int,
        temperature: Double? = nil,
        reasoning: OpenRouterReasoning? = nil
    ) async throws -> (content: String, usage: OpenRouterUsage?, finishReason: String?) {
        do {
            return try await send(
                messages: messages,
                model: model,
                responseFormat: responseFormat,
                maxTokens: maxTokens,
                temperature: temperature,
                reasoning: reasoning
            )
        } catch let OpenRouterError.httpError(status, _)
            where (status == 400 || status == 404) && responseFormat.isJSONSchema {
            // Provider can't honor the strict schema; fall back to a plain JSON
            // object so no-train-provider compatibility is preserved.
            return try await send(
                messages: messages,
                model: model,
                responseFormat: .jsonObject,
                maxTokens: maxTokens,
                temperature: temperature,
                reasoning: reasoning
            )
        }
    }

    /// Performs a single chat-completions request with the given response format.
    private func send(
        messages: [ChatMessage],
        model: String,
        responseFormat: OpenRouterResponseFormat,
        maxTokens: Int,
        temperature: Double?,
        reasoning: OpenRouterReasoning?
    ) async throws -> (content: String, usage: OpenRouterUsage?, finishReason: String?) {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Optional attribution headers (no secrets).
        request.setValue("https://kleoth.dev", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Kleoth", forHTTPHeaderField: "X-Title")

        request.httpBody = try Self.makeBody(
            messages: messages,
            model: model,
            responseFormat: responseFormat,
            maxTokens: maxTokens,
            temperature: temperature,
            reasoning: reasoning
        )

        let (data, response) = try await transport.data(for: request)

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(statusCode) else {
            throw OpenRouterError.httpError(status: statusCode, bodySnippet: Self.snippet(data))
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(ResponseBody.self, from: data)

        // A 2xx with no choices at all is a genuine empty response. But a choice
        // whose content is empty/nil (e.g. a reasoning model that spent the whole
        // output budget thinking → `finish_reason == "length"`) is NOT thrown
        // here: it's returned with its finish reason so the summarizer can route
        // it into the repair/retry path instead of failing outright.
        guard let choice = decoded.choices?.first else {
            throw OpenRouterError.noContent
        }

        return (choice.message?.content ?? "", decoded.usage, choice.finishReason)
    }

    /// Builds the JSON request body. Uses `JSONSerialization` (rather than a
    /// `Codable` struct) so a raw JSON-schema document embeds verbatim under
    /// `response_format.json_schema.schema`.
    private static func makeBody(
        messages: [ChatMessage],
        model: String,
        responseFormat: OpenRouterResponseFormat,
        maxTokens: Int,
        temperature: Double?,
        reasoning: OpenRouterReasoning?
    ) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "max_tokens": maxTokens,
            "provider": ["require_parameters": true],
        ]

        // Only written when the caller asked for one, so `Summarizer`'s body is
        // unchanged from before the parameter existed.
        if let temperature {
            body["temperature"] = temperature
        }
        if let reasoning {
            body["reasoning"] = reasoning.bodyValue
        }

        switch responseFormat {
        case .none:
            break
        case .jsonObject:
            body["response_format"] = ["type": "json_object"]
        case let .jsonSchema(name, schemaJSON):
            let schema = try JSONSerialization.jsonObject(
                with: Data(schemaJSON.utf8)
            )
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": name,
                    "strict": true,
                    "schema": schema,
                ],
            ]
        }

        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Returns a bounded, UTF-8-decoded snippet of a response body for error messages.
    private static func snippet(_ data: Data, limit: Int = 500) -> String {
        let bounded = data.prefix(limit)
        let text = String(decoding: bounded, as: UTF8.self)
        return data.count > limit ? text + "…" : text
    }
}
