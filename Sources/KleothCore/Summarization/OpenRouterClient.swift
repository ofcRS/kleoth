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

    // MARK: - Request body

    private struct ResponseFormat: Encodable {
        let type: String
    }

    private struct ProviderPreferences: Encodable {
        let requireParameters: Bool
    }

    private struct RequestBody: Encodable {
        let model: String
        let messages: [ChatMessage]
        let maxTokens: Int
        let responseFormat: ResponseFormat?
        let provider: ProviderPreferences
    }

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
    /// - Parameter jsonObject: when `true`, requests
    ///   `response_format: {type: "json_object"}`.
    public func complete(
        messages: [ChatMessage],
        model: String,
        jsonObject: Bool,
        maxTokens: Int
    ) async throws -> (content: String, usage: OpenRouterUsage?) {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Optional attribution headers (no secrets).
        request.setValue("https://kleoth.dev", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Kleoth", forHTTPHeaderField: "X-Title")

        let body = RequestBody(
            model: model,
            messages: messages,
            maxTokens: maxTokens,
            responseFormat: jsonObject ? ResponseFormat(type: "json_object") : nil,
            provider: ProviderPreferences(requireParameters: true)
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(body)

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

    /// Returns a bounded, UTF-8-decoded snippet of a response body for error messages.
    private static func snippet(_ data: Data, limit: Int = 500) -> String {
        let bounded = data.prefix(limit)
        let text = String(decoding: bounded, as: UTF8.self)
        return data.count > limit ? text + "…" : text
    }
}
