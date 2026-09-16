import Foundation

/// Usage / cost metadata of one completion. `cost` is USD as reported by the
/// backend — only OpenRouter reports one; every other provider leaves it nil,
/// which callers already read as 0.
public struct ChatUsage: Codable, Sendable, Equatable {
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let cost: Double?

    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, cost: Double? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cost = cost
    }
}

/// The pre-provider name of ``ChatUsage``. Kept so existing call sites and
/// tests compile unchanged.
public typealias OpenRouterUsage = ChatUsage

/// One completed chat call, whichever backend produced it.
public struct ChatCompletion: Sendable, Equatable {
    public let content: String
    public let usage: ChatUsage?
    /// `"stop"` when complete, `"length"` when the output cap was hit (the
    /// summarizer's repair path keys on this), otherwise backend-specific.
    public let finishReason: String?

    public init(content: String, usage: ChatUsage? = nil, finishReason: String? = nil) {
        self.content = content
        self.usage = usage
        self.finishReason = finishReason
    }
}

/// The one function every language-model backend implements. `Summarizer`
/// and `DictationPolisher` depend on this, never on a concrete client.
///
/// `responseFormat` / `temperature` / `reasoning` are requests, not
/// guarantees: an adapter whose backend has no equivalent ignores them
/// (Claude Code has no temperature flag; Codex has no system-prompt flag).
public protocol ChatCompleting: Sendable {
    func complete(
        messages: [ChatMessage],
        model: String,
        responseFormat: OpenRouterResponseFormat,
        maxTokens: Int,
        temperature: Double?,
        reasoning: OpenRouterReasoning?
    ) async throws -> ChatCompletion
}

public extension ChatCompleting {
    /// The summarizer's call shape: no temperature, no reasoning cap.
    func complete(
        messages: [ChatMessage],
        model: String,
        responseFormat: OpenRouterResponseFormat,
        maxTokens: Int
    ) async throws -> ChatCompletion {
        try await complete(messages: messages, model: model, responseFormat: responseFormat,
                           maxTokens: maxTokens, temperature: nil, reasoning: nil)
    }
}

public extension ChatMessage {
    /// Collapses a chat transcript into what a single-turn backend takes: the
    /// first `system` message on its own, and every other turn as one prompt.
    /// A lone user turn is passed verbatim; several turns are labelled
    /// `User:` / `Assistant:` blocks (the summarizer's repair retry is the only
    /// multi-turn caller).
    static func flattenForSingleTurn(_ messages: [ChatMessage]) -> (system: String?, prompt: String) {
        let system = messages.first { $0.role == "system" }?.content
        let turns = messages.filter { $0.role != "system" }
        if turns.count == 1 {
            return (system, turns[0].content)
        }
        let prompt = turns.map { turn -> String in
            let label = turn.role == "assistant" ? "Assistant" : "User"
            return "\(label):\n\(turn.content)"
        }.joined(separator: "\n\n")
        return (system, prompt)
    }
}
