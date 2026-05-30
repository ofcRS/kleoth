import Foundation

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
        fatalError("unimplemented")
    }
}
