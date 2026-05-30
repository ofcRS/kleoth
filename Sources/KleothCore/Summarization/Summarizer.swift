import Foundation

/// Errors thrown by ``Summarizer``.
public enum SummarizerError: Error, Sendable {
    /// The transcript exceeds the single-shot token budget. Map-reduce
    /// summarization is intentionally deferred, so this is surfaced rather
    /// than silently truncating.
    case transcriptTooLong(approxTokens: Int)
    /// The model produced output that could not be decoded into a
    /// ``MeetingSummary`` even after one repair attempt. Carries a snippet
    /// of the offending content.
    case invalidJSON(snippet: String)
}

/// Produces a structured `MeetingSummary` from a normalized transcript,
/// using an `OpenRouterClient`.
public struct Summarizer {
    public let client: OpenRouterClient
    public var model: String

    public init(client: OpenRouterClient, model: String = "anthropic/claude-haiku-4.5") {
        self.client = client
        self.model = model
    }

    /// Approximate token-budget ceiling for the user content. Above this we
    /// refuse rather than attempt a doomed single-shot request.
    private static let tokenLimit = 180_000
    /// Maximum output tokens requested from the model.
    private static let maxOutputTokens = 4096

    private static let systemPrompt = """
    You are a meeting summarizer. You receive a diarized transcript with real speaker names and timestamps. Be precise and factual. Do not invent information. If something is ambiguous, say so. Output ONLY valid JSON matching this schema:
    {
      "tldr": "string",
      "decisions": ["string"],
      "action_items": [{ "owner": "string", "task": "string", "due": "string or null" }],
      "key_points": ["string"],
      "per_speaker_highlights": [{ "speaker": "string", "highlights": ["string"] }],
      "open_questions": ["string"],
      "suggested_tags": ["string"]
    }
    Use the exact participant names provided. Only include an action item if a concrete task was stated or clearly implied; if the owner is unstated use "unassigned", and if the due date is unstated use null.
    """

    /// Summarizes the transcript and returns the summary plus the USD cost
    /// of the completion.
    public func summarize(
        transcript: Transcript,
        metadata: MeetingMetadata
    ) async throws -> (summary: MeetingSummary, costUSD: Double) {
        let userContent = Self.buildUserContent(transcript: transcript, metadata: metadata)

        // Token guard: rough heuristic of ~4 characters per token.
        let approxTokens = userContent.count / 4
        if approxTokens > Self.tokenLimit {
            throw SummarizerError.transcriptTooLong(approxTokens: approxTokens)
        }

        let baseMessages = [
            ChatMessage(role: "system", content: Self.systemPrompt),
            ChatMessage(role: "user", content: userContent),
        ]

        // First attempt.
        let first = try await client.complete(
            messages: baseMessages,
            model: model,
            jsonObject: true,
            maxTokens: Self.maxOutputTokens
        )

        if let summary = Self.decodeSummary(from: first.content) {
            return (summary, first.usage?.cost ?? 0)
        }

        // One repair retry: feed back the bad content and ask for clean JSON.
        let repairMessages = baseMessages + [
            ChatMessage(role: "assistant", content: first.content),
            ChatMessage(
                role: "user",
                content: "Your previous response was not valid JSON. Return ONLY the JSON object — no prose, no markdown fences."
            ),
        ]

        let retry = try await client.complete(
            messages: repairMessages,
            model: model,
            jsonObject: true,
            maxTokens: Self.maxOutputTokens
        )

        let costUSD = (first.usage?.cost ?? 0) + (retry.usage?.cost ?? 0)

        guard let summary = Self.decodeSummary(from: retry.content) else {
            throw SummarizerError.invalidJSON(snippet: Self.snippet(retry.content))
        }

        return (summary, costUSD)
    }

    // MARK: - Prompt construction

    private static func buildUserContent(transcript: Transcript, metadata: MeetingMetadata) -> String {
        let participants = metadata.participants.joined(separator: ", ")
        let lines = transcript.utterances.map { utterance -> String in
            let speaker = utterance.speakerName ?? utterance.speakerId
            return "\(speaker): \(utterance.text)"
        }
        let transcriptText = lines.joined(separator: "\n")

        return """
        Meeting: \(metadata.title)
        Date: \(metadata.date)
        Participants: \(participants)

        Transcript:
        \(transcriptText)
        """
    }

    // MARK: - Response parsing

    /// Strips surrounding whitespace and ```json / ``` code fences, then
    /// attempts to decode a ``MeetingSummary`` using snake_case mapping.
    /// Returns `nil` on any decode failure.
    private static func decodeSummary(from content: String) -> MeetingSummary? {
        let cleaned = stripCodeFences(content)
        guard let data = cleaned.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(MeetingSummary.self, from: data)
    }

    /// Removes leading/trailing whitespace and a wrapping fenced code block
    /// (```json … ``` or ``` … ```), if present.
    static func stripCodeFences(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        guard text.hasPrefix("```") else { return text }

        // Drop the opening fence line (e.g. "```" or "```json").
        if let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        } else {
            // Single line that is only a fence; nothing usable remains.
            return ""
        }

        // Drop a trailing closing fence if present.
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("```") {
            text = String(text.dropLast(3))
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns a bounded snippet of model output for error messages.
    private static func snippet(_ content: String, limit: Int = 500) -> String {
        if content.count <= limit { return content }
        return String(content.prefix(limit)) + "…"
    }
}
