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

    public init(client: OpenRouterClient, model: String = "openai/gpt-4.1-mini") {
        self.client = client
        self.model = model
    }

    /// Approximate token-budget ceiling for the user content. Above this we
    /// refuse rather than attempt a doomed single-shot request.
    private static let tokenLimit = 180_000
    /// Maximum output tokens requested from the model.
    private static let maxOutputTokens = 4096

    private static let systemPrompt = """
    You are a meeting summarizer. You receive a diarized transcript with real speaker names and timestamps. Be precise and factual. Do not invent information. If something is ambiguous, say so.

    Write every natural-language value you produce — title, tldr, decisions, every action item task, key_points, per_speaker_highlights, open_questions, and suggested_tags — in the SAME language as the transcript below. Do NOT translate it into English or any other language; mirror the transcript's language exactly. Keep speaker and owner names exactly as given.

    Output ONLY valid JSON matching this schema:
    {
      "title": "string",
      "tldr": "string",
      "decisions": ["string"],
      "action_items": [{ "owner": "string", "task": "string", "due": "string or null" }],
      "key_points": ["string"],
      "per_speaker_highlights": [{ "speaker": "string", "highlights": ["string"] }],
      "open_questions": ["string"],
      "suggested_tags": ["string"]
    }
    Also produce "title": a concise, specific 4-8 word meeting title.
    Use the exact participant names provided. Only include an action item if a concrete task was stated or clearly implied; if the owner is unstated use "unassigned", and if the due date is unstated use null.
    """

    /// Strict JSON schema for ``MeetingSummary`` (snake_case keys), sent as the
    /// `json_schema` response format. All fields are required (the model emits
    /// every key; `title` is still decoded as optional for older summaries and
    /// the `json_object` fallback). `additionalProperties` is disabled so the
    /// provider can enforce the shape exactly.
    static let schemaJSON = """
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["title", "tldr", "decisions", "action_items", "key_points", "per_speaker_highlights", "open_questions", "suggested_tags"],
      "properties": {
        "title": { "type": "string" },
        "tldr": { "type": "string" },
        "decisions": { "type": "array", "items": { "type": "string" } },
        "action_items": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["owner", "task", "due"],
            "properties": {
              "owner": { "type": "string" },
              "task": { "type": "string" },
              "due": { "type": ["string", "null"] }
            }
          }
        },
        "key_points": { "type": "array", "items": { "type": "string" } },
        "per_speaker_highlights": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["speaker", "highlights"],
            "properties": {
              "speaker": { "type": "string" },
              "highlights": { "type": "array", "items": { "type": "string" } }
            }
          }
        },
        "open_questions": { "type": "array", "items": { "type": "string" } },
        "suggested_tags": { "type": "array", "items": { "type": "string" } }
      }
    }
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

        // Request a strict JSON schema for robust, well-shaped output; the
        // client transparently falls back to a plain JSON object for providers
        // that can't honor the schema.
        let responseFormat: OpenRouterResponseFormat = .jsonSchema(
            name: "meeting_summary",
            schemaJSON: Self.schemaJSON
        )

        // First attempt.
        let first = try await client.complete(
            messages: baseMessages,
            model: model,
            responseFormat: responseFormat,
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
            responseFormat: responseFormat,
            maxTokens: Self.maxOutputTokens
        )

        let costUSD = (first.usage?.cost ?? 0) + (retry.usage?.cost ?? 0)

        guard let summary = Self.decodeSummary(from: retry.content) else {
            throw SummarizerError.invalidJSON(snippet: Self.snippet(retry.content))
        }

        return (summary, costUSD)
    }

    // MARK: - Prompt construction

    /// The English name of an ISO language code (e.g. `"rus"`/`"ru"` → `"Russian"`),
    /// or `nil` when the code is empty or unrecognized. Used to name the
    /// transcript's language in the prompt so the model writes the summary in it.
    ///
    /// Handles both forms the pipeline emits: WhisperKit reports ISO 639-1
    /// (2-letter, `"ru"`); ElevenLabs Scribe reports ISO 639-2/T (3-letter,
    /// `"rus"`). Unknown codes return `nil` — the system prompt's "same language
    /// as the transcript" rule is the fallback — rather than guessing a name.
    static func languageName(for code: String?) -> String? {
        guard let raw = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        // Primary subtag only: "ru-RU" / "ru_RU" → "ru".
        let base = String(raw.prefix { $0 != "-" && $0 != "_" })
        guard !base.isEmpty else { return nil }

        // Map the 3-letter codes the pipeline realistically sees down to the
        // 2-letter codes Foundation can name.
        let threeToTwo: [String: String] = [
            "eng": "en", "rus": "ru", "ukr": "uk", "deu": "de", "ger": "de",
            "fra": "fr", "fre": "fr", "spa": "es", "ita": "it", "por": "pt",
            "nld": "nl", "dut": "nl", "pol": "pl", "tur": "tr", "ara": "ar",
            "zho": "zh", "chi": "zh", "jpn": "ja", "kor": "ko", "ces": "cs",
            "cze": "cs", "ron": "ro", "rum": "ro", "ell": "el", "gre": "el",
        ]
        let twoLetter = base.count == 3 ? (threeToTwo[base] ?? base) : base

        let english = Locale(identifier: "en_US")
        if let name = english.localizedString(forLanguageCode: twoLetter),
           name.lowercased() != twoLetter {
            return name
        }
        return nil
    }

    private static func buildUserContent(transcript: Transcript, metadata: MeetingMetadata) -> String {
        let participants = metadata.participants.joined(separator: ", ")
        let lines = transcript.utterances.map { utterance -> String in
            let speaker = utterance.speakerName ?? utterance.speakerId
            return "\(speaker): \(utterance.text)"
        }
        let transcriptText = lines.joined(separator: "\n")

        var header = """
        Meeting: \(metadata.title)
        Date: \(metadata.date)
        Participants: \(participants)
        """
        // Name the detected language so the model writes the summary in it rather
        // than defaulting to English (the language of these instructions). Prefer
        // the transcript's own detected code; fall back to the meeting metadata.
        if let name = languageName(for: transcript.languageCode ?? metadata.languageCode) {
            header += "\nTranscript language: \(name). Write the entire summary in \(name)."
        }

        return """
        \(header)

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
