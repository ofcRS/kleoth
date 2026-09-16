import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Chat-completions client for any server that speaks the OpenAI shape:
/// OpenRouter, Ollama (`http://localhost:11434/v1`), LM Studio
/// (`http://localhost:1234/v1`), vLLM, a corporate gateway.
///
/// Errors are still `OpenRouterError` (the HTTP failure type every caller
/// pattern-matches), except a local server's "model not found" 404, which is
/// rewritten to `ProviderError.modelMissing` so the user gets the pull command
/// instead of a retry.
public struct OpenAICompatibleClient: ChatCompleting {
    /// The API root, e.g. `http://localhost:11434/v1`. `chat/completions` is appended.
    public let baseURL: URL
    /// Bearer token; nil sends no `Authorization` header (Ollama needs none).
    public let apiKey: String?
    public let transport: HTTPTransport
    /// OpenRouter-only: `provider.require_parameters: true` in the body.
    /// Ollama and LM Studio reject unknown top-level keys, so it is off by default.
    public let sendsOpenRouterProviderKey: Bool

    public init(baseURL: URL, apiKey: String?, transport: HTTPTransport, sendsOpenRouterProviderKey: Bool = false) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.transport = transport
        self.sendsOpenRouterProviderKey = sendsOpenRouterProviderKey
    }

    var endpoint: URL {
        baseURL.appendingPathComponent("chat/completions")
    }

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
    ///   default) — again so `Summarizer`'s body is unchanged.
    ///
    /// **Fallback retry.** The body always carries `provider.require_parameters:
    /// true`, so OpenRouter routes only to endpoints that declare support for
    /// EVERY parameter sent — the strict `json_schema`, `temperature` and
    /// `reasoning` alike. Under this account's data-policy guardrails that can
    /// leave zero eligible endpoints and the request fails with HTTP 400 or 404
    /// (no-train providers reject the strict schema; the ZDR guardrail 404s
    /// `google/gemini-3.8-flash` only when `temperature` is present — measured
    /// live 2026-09-03: schema + temperature → 404 `zdr-violation-by-account`,
    /// the same body without `temperature` → 200; `reasoning` did the same on
    /// `meta-llama/llama-3.3-70b-instruct`). On a 400/404 the call therefore
    /// retries ONCE with everything that narrows routing removed: a `.jsonSchema`
    /// format is downgraded to `.jsonObject`, and `temperature` / `reasoning`
    /// are dropped. A single relaxed retry (rather than a ladder) keeps the
    /// worst case at two round trips, which matters inside the 8 s dictation
    /// budget. The retry is skipped when it would re-send an identical body
    /// (already `.jsonObject`/`.none` with no temperature or reasoning).
    public func complete(
        messages: [ChatMessage],
        model: String,
        responseFormat: OpenRouterResponseFormat,
        maxTokens: Int,
        temperature: Double? = nil,
        reasoning: OpenRouterReasoning? = nil
    ) async throws -> ChatCompletion {
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
            where (status == 400 || status == 404)
                && Self.hasRoutingNarrowingParameters(responseFormat, temperature, reasoning) {
            // No endpoint could honor every parameter under `require_parameters`;
            // retry once with the routing-narrowing ones removed (strict schema →
            // plain JSON object, no temperature, no reasoning).
            return try await send(
                messages: messages,
                model: model,
                responseFormat: responseFormat.isJSONSchema ? .jsonObject : responseFormat,
                maxTokens: maxTokens,
                temperature: nil,
                reasoning: nil
            )
        }
    }

    /// Whether the relaxed retry would send a different body than the first
    /// attempt — i.e. whether there is anything left to drop.
    private static func hasRoutingNarrowingParameters(
        _ responseFormat: OpenRouterResponseFormat,
        _ temperature: Double?,
        _ reasoning: OpenRouterReasoning?
    ) -> Bool {
        responseFormat.isJSONSchema || temperature != nil || reasoning != nil
    }

    /// Performs a single chat-completions request with the given response format.
    private func send(
        messages: [ChatMessage],
        model: String,
        responseFormat: OpenRouterResponseFormat,
        maxTokens: Int,
        temperature: Double?,
        reasoning: OpenRouterReasoning?
    ) async throws -> ChatCompletion {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if sendsOpenRouterProviderKey {
            // Optional attribution headers (no secrets) — OpenRouter only.
            request.setValue("https://kleoth.dev", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Kleoth", forHTTPHeaderField: "X-Title")
        }

        request.httpBody = try Self.makeBody(
            messages: messages,
            model: model,
            responseFormat: responseFormat,
            maxTokens: maxTokens,
            temperature: temperature,
            reasoning: reasoning,
            providerKey: sendsOpenRouterProviderKey
        )

        let (data, response) = try await transport.data(for: request)

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(statusCode) else {
            // Local servers only: OpenRouter's own 404s ("no endpoints matching
            // your data policy", a ZDR violation) must stay `OpenRouterError` so
            // the relaxed retry above still fires — rewriting them to
            // `modelMissing` would abort the call with an `ollama pull` hint.
            if statusCode == 404, !sendsOpenRouterProviderKey,
               let hint = Self.pullHint(model: model, body: data) {
                throw ProviderError.modelMissing(model: model, hint: hint)
            }
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

        return ChatCompletion(content: choice.message?.content ?? "", usage: decoded.usage, finishReason: choice.finishReason)
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
        reasoning: OpenRouterReasoning?,
        providerKey: Bool
    ) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "max_tokens": maxTokens,
        ]
        if providerKey {
            body["provider"] = ["require_parameters": true]
        }

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

    /// Ollama's 404 for an unpulled model reads `model "x" not found, try
    /// pulling it first`. Recognized by both phrases so a different server's
    /// 404 (bad path) stays an `OpenRouterError`.
    static func pullHint(model: String, body: Data) -> String? {
        let text = String(decoding: body, as: UTF8.self).lowercased()
        guard text.contains("not found"), text.contains("pull") else { return nil }
        return "ollama pull \(model)"
    }
}
