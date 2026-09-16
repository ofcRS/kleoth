import Foundation
@testable import KleothCore

/// A canned `ChatCompleting` for tests: records every call, replays results in
/// order (the last one repeats once exhausted).
final class MockChatClient: ChatCompleting, @unchecked Sendable {
    struct Call: Sendable {
        let messages: [ChatMessage]
        let model: String
        let responseFormat: OpenRouterResponseFormat
        let maxTokens: Int
        let temperature: Double?
        let reasoning: OpenRouterReasoning?
    }

    private let lock = NSLock()
    private let results: [Result<ChatCompletion, Error>]
    private var index = 0
    private(set) var calls: [Call] = []

    init(results: [Result<ChatCompletion, Error>]) {
        self.results = results
    }

    func complete(
        messages: [ChatMessage], model: String, responseFormat: OpenRouterResponseFormat,
        maxTokens: Int, temperature: Double?, reasoning: OpenRouterReasoning?
    ) async throws -> ChatCompletion {
        let result = lock.withLock { () -> Result<ChatCompletion, Error> in
            calls.append(Call(messages: messages, model: model, responseFormat: responseFormat,
                              maxTokens: maxTokens, temperature: temperature, reasoning: reasoning))
            let result = results[min(index, results.count - 1)]
            if index < results.count - 1 { index += 1 }
            return result
        }
        return try result.get()
    }
}
