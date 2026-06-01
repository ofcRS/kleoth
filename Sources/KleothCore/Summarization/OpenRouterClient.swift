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

/// Client for the OpenRouter chat completions endpoint.
///
/// POST `https://openrouter.ai/api/v1/chat/completions`, authenticated with
/// `Authorization: Bearer <key>`.
public struct OpenRouterClient {
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
        }
        let choices: [Choice]?
        let usage: OpenRouterUsage?
    }

    /// Requests a chat completion and returns the message content plus
    /// optional usage metadata.
    ///
    /// - Parameter responseFormat: how the response shape is constrained
    ///   (none / `json_object` / strict `json_schema`).
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
        maxTokens: Int
    ) async throws -> (content: String, usage: OpenRouterUsage?) {
        do {
            return try await send(
                messages: messages,
                model: model,
                responseFormat: responseFormat,
                maxTokens: maxTokens
            )
        } catch let OpenRouterError.httpError(status, _)
            where (status == 400 || status == 404) && responseFormat.isJSONSchema {
            // Provider can't honor the strict schema; fall back to a plain JSON
            // object so no-train-provider compatibility is preserved.
            return try await send(
                messages: messages,
                model: model,
                responseFormat: .jsonObject,
                maxTokens: maxTokens
            )
        }
    }

    /// Performs a single chat-completions request with the given response format.
    private func send(
        messages: [ChatMessage],
        model: String,
        responseFormat: OpenRouterResponseFormat,
        maxTokens: Int
    ) async throws -> (content: String, usage: OpenRouterUsage?) {
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
            maxTokens: maxTokens
        )

        let (data, response) = try await transport.data(for: request)

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(statusCode) else {
            throw OpenRouterError.httpError(status: statusCode, bodySnippet: Self.snippet(data))
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(ResponseBody.self, from: data)

        guard let content = decoded.choices?.first?.message?.content else {
            throw OpenRouterError.noContent
        }

        return (content, decoded.usage)
    }

    /// Builds the JSON request body. Uses `JSONSerialization` (rather than a
    /// `Codable` struct) so a raw JSON-schema document embeds verbatim under
    /// `response_format.json_schema.schema`.
    private static func makeBody(
        messages: [ChatMessage],
        model: String,
        responseFormat: OpenRouterResponseFormat,
        maxTokens: Int
    ) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "max_tokens": maxTokens,
            "provider": ["require_parameters": true],
        ]

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
