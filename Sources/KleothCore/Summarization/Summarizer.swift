import Foundation

/// Errors thrown by ``Summarizer``.
///
/// Apart from `transcriptTooLong`, each case describes the retry's answer —
/// the last one — whatever was wrong with the first: an empty first answer
/// whose retry was cut off ends `.truncated`, an incomplete one whose repair
/// came back as prose ends `invalidJSON`.
public enum SummarizerError: Error, Sendable {
    /// The transcript exceeds the single-shot token budget. Map-reduce
    /// summarization is intentionally deferred, so this is surfaced rather
    /// than silently truncating.
    case transcriptTooLong(approxTokens: Int)
    /// The retry's answer could not be decoded into a ``MeetingSummary``: not
    /// a JSON object, or one whose values are of the wrong type. Carries a
    /// snippet of it — empty when the retry came back with nothing.
    case invalidJSON(snippet: String)
    /// The retry's answer ran out of output room before its JSON closed — or,
    /// after a cut-off first answer, the provider refused the retry's doubled
    /// budget (HTTP 400/404: above the model's output limit). Nothing partial
    /// is kept.
    case truncated
    /// The retry's answer was a complete JSON object without every part the
    /// prompt asks for. Keys as the prompt spells them: `tldr`, `overview`,
    /// `action_items`, `per_speaker_highlights`.
    case incomplete(missing: [String])
}

extension SummarizerError: LocalizedError {
    // Readable messages for the user-facing `summaryError` line.
    public var errorDescription: String? {
        switch self {
        case let .transcriptTooLong(approxTokens):
            return "Transcript is too long to summarize in one pass (~\(approxTokens) tokens)."
        case let .invalidJSON(snippet):
            return snippet.isEmpty
                ? "The model returned an empty answer."
                : "The model did not return a complete summary. Got: \(snippet)"
        case .truncated:
            return "The summary was cut off: the model ran out of output room before finishing (reasoning models spend part of it thinking). Try again, or use another model."
        case let .incomplete(missing):
            let parts = missing.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ")
            return "The summary came back incomplete (no \(parts)). Try again, or use another model."
        }
    }
}

/// Produces a structured `MeetingSummary` from a normalized transcript,
/// using any ``ChatCompleting`` backend.
public struct Summarizer: Sendable {
    public let client: any ChatCompleting
    public var model: String
    /// Output tokens the first request asks for; the retry after a cut-off
    /// answer asks for twice this. Backends with no output cap (the Claude Code
    /// and Codex CLIs) ignore it — for them the retry's compact instruction is
    /// what makes the answer fit. Clamped to 1…1,000,000 on every write, so the
    /// doubling can't overflow and a nonsense budget never reaches a provider.
    public var maxOutputTokens: Int {
        didSet { maxOutputTokens = Self.clampedOutputTokens(maxOutputTokens) }
    }

    public init(client: any ChatCompleting, model: String = ModelCatalog.defaultModel,
                maxOutputTokens: Int = Summarizer.defaultMaxOutputTokens) {
        self.client = client
        self.model = model
        // An initializer's writes skip `didSet`, so this one clamps itself.
        self.maxOutputTokens = Self.clampedOutputTokens(maxOutputTokens)
    }

    /// Approximate token-budget ceiling for the user content. Above this we
    /// refuse rather than attempt a doomed single-shot request.
    private static let tokenLimit = 180_000
    /// The default ``maxOutputTokens``. Generous because the `overview` is
    /// deliberately detailed multi-paragraph prose (and non-Latin scripts
    /// tokenize heavier), and reasoning models spend part of it thinking.
    public static let defaultMaxOutputTokens = 8192

    /// `tokens` within 1…1,000,000: far above any model's output limit, and
    /// far enough below `Int.max` for the cut-off retry to double it.
    private static func clampedOutputTokens(_ tokens: Int) -> Int {
        min(max(tokens, 1), 1_000_000)
    }

    private static let systemPrompt = """
    You are a meeting summarizer. You receive a diarized transcript with real speaker names and timestamps. Be precise and factual. Do not invent information. If something is ambiguous, say so.

    Write every natural-language value you produce — title, tldr, overview, every action item task, and per_speaker_highlights — in the SAME language as the transcript below. Do NOT translate it into English or any other language; mirror the transcript's language exactly. Keep speaker and owner names exactly as given.

    Output ONLY valid JSON matching this schema:
    {
      "title": "string",
      "tldr": "string",
      "overview": "string",
      "action_items": [{ "owner": "string", "task": "string", "due": "string or null" }],
      "per_speaker_highlights": [{ "speaker": "string", "highlights": ["string"] }]
    }
    "title": a concise, specific 4-8 word meeting title.
    "tldr": 2-4 sentences capturing the essence of the meeting.
    "overview": a detailed, faithful overview of the whole meeting — what was discussed and in what order, the context and reasoning behind each topic, concrete specifics (names, numbers, dates, agreements and who made them), and how things were left. Write it as flowing prose in several paragraphs separated by blank lines — no bullet lists, no headings. Make it complete enough that someone who missed the meeting needs nothing else.
    "per_speaker_highlights": for each speaker, their most important statements, positions, and commitments.
    Only include an action item if a concrete task was stated or clearly implied; if the owner is unstated use "unassigned", and if the due date is unstated use null.
    """

    /// Strict JSON schema for ``MeetingSummary`` (snake_case keys), sent as the
    /// `json_schema` response format. All fields are required (the model emits
    /// every key; `title`/`overview` are still decoded as optional for older
    /// summaries and the `json_object` fallback). `additionalProperties` is
    /// disabled so the provider can enforce the shape exactly.
    static let schemaJSON = """
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["title", "tldr", "overview", "action_items", "per_speaker_highlights"],
      "properties": {
        "title": { "type": "string", "description": "Concise, specific 4-8 word meeting title, in the transcript's language." },
        "tldr": { "type": "string", "description": "2-4 sentences capturing the essence of the meeting." },
        "overview": { "type": "string", "description": "Detailed multi-paragraph prose overview of the entire meeting, in the transcript's language. Paragraphs separated by blank lines; no bullets or headings." },
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
        }
      }
    }
    """

    /// Appended to the user message of the retry after a cut-off answer: the
    /// same request, which now fits only if the model writes less.
    static let compactRetryInstruction = "Your previous answer was cut off before the JSON was complete. Answer again, more compactly — a shorter overview and fewer highlights — in the same language and the same JSON shape."

    /// Summarizes the transcript and returns the summary plus the USD cost
    /// of the completions.
    ///
    /// An answer becomes a summary only when ``assess(_:)`` finds it complete:
    /// not cut off, decodable, and carrying every part the prompt asks for. A
    /// first answer short of that gets one retry, shaped by what was wrong with
    /// it; after the retry anything short of a complete answer throws
    /// (``SummarizerError``), so a partial summary is never passed off as finished.
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
            maxTokens: maxOutputTokens
        )

        // One retry, shaped by what was wrong with the first answer. By default
        // it is the first request again, unchanged.
        var retryMessages = baseMessages
        var retryMaxTokens = maxOutputTokens
        var retryReasoning: OpenRouterReasoning?
        var wasCutOff = false
        switch Self.assess(first) {
        case let .complete(summary):
            return (summary, first.usage?.cost ?? 0)

        case let .cutOff(hadText):
            // Ask again fresh — the original messages plus a request to be more
            // compact — with twice the room. Replaying the partial text would
            // give the model more input and the same room, so the retry would
            // be cut off again.
            wasCutOff = true
            retryMessages = [
                baseMessages[0],
                ChatMessage(role: "user", content: userContent + "\n\n" + Self.compactRetryInstruction),
            ]
            retryMaxTokens = maxOutputTokens * 2
            // Nothing at all came back: the budget went on reasoning, so ask for
            // less of it. Only then — an answer with text ran out while writing,
            // and on Anthropic models `low` would switch thinking on.
            if !hadText { retryReasoning = .low }

        case .empty:
            // Ask again unchanged. An empty answer is never replayed: Anthropic's
            // API and strict OpenAI-compatible upstreams reject an empty
            // non-final assistant turn with HTTP 400.
            break

        case let .incomplete(missing):
            // A complete object without every part: feed it back and name what
            // is missing, so the model keeps what it wrote and adds the rest.
            retryMessages = baseMessages + [
                ChatMessage(role: "assistant", content: first.content),
                ChatMessage(
                    role: "user",
                    content: "Your previous answer is missing: \(missing.joined(separator: ", ")). Return the complete JSON object with every key — no prose, no markdown fences."
                ),
            ]

        case .malformed:
            // Not JSON (or a shape that won't decode): feed it back so the model
            // can fix the shape.
            retryMessages = baseMessages + [
                ChatMessage(role: "assistant", content: first.content),
                ChatMessage(
                    role: "user",
                    content: "Your previous response was not valid JSON. Return ONLY the JSON object — no prose, no markdown fences."
                ),
            ]
        }

        let retry: ChatCompletion
        do {
            retry = try await client.complete(
                messages: retryMessages,
                model: model,
                responseFormat: responseFormat,
                maxTokens: retryMaxTokens,
                temperature: nil,
                reasoning: retryReasoning
            )
        } catch let OpenRouterError.httpError(status, _) where wasCutOff && (status == 400 || status == 404) {
            // The doubled budget is above this model's output limit (and the
            // client's relaxed retry didn't help): the summary can't fit, which
            // is what the user needs to hear, not an HTTP error about max_tokens.
            throw SummarizerError.truncated
        }

        let costUSD = (first.usage?.cost ?? 0) + (retry.usage?.cost ?? 0)

        // Anything short of a complete answer now throws rather than pass for a
        // summary: the pipeline records it as `summaryError` and keeps the
        // transcript.
        switch Self.assess(retry) {
        case let .complete(summary):
            return (summary, costUSD)
        case .cutOff:
            throw SummarizerError.truncated
        case let .incomplete(missing):
            throw SummarizerError.incomplete(missing: missing)
        case .empty:
            throw SummarizerError.invalidJSON(snippet: "")
        case .malformed:
            throw SummarizerError.invalidJSON(snippet: Self.snippet(retry.content))
        }
    }

    /// Whether a completion's `finish_reason` indicates a truncated (incomplete)
    /// response — i.e. it hit the output token cap.
    static func isTruncated(_ finishReason: String?) -> Bool {
        finishReason?.lowercased() == "length"
    }

    // MARK: - Assessing an answer

    /// What ``assess(_:)`` makes of an answer; each kind gets its own retry.
    enum Assessment {
        /// Not cut off, decodable, every part present.
        case complete(MeetingSummary)
        /// Out of output room before the JSON closed. `hadText == false` —
        /// nothing at all came back — means the budget went on reasoning.
        case cutOff(hadText: Bool)
        /// Nothing came back, and not because of the cap.
        case empty
        /// A complete JSON object without some of the parts the prompt asks for.
        case incomplete(missing: [String])
        /// Not a JSON object (prose, an array), or one with every part whose
        /// values won't decode (a wrong type).
        case malformed
    }

    /// Classifies a completion for every provider alike. A cut-off shows either
    /// way: the finish reason `length`, or — because Codex, Claude Code and some
    /// local servers report `stop` regardless — a JSON object that stops before
    /// it closes. Any other JSON object is judged by its parts before it is
    /// decoded, so a missing `tldr` is asked for by name like any other part.
    static func assess(_ completion: ChatCompletion) -> Assessment {
        let text = stripCodeFences(completion.content)
        if isTruncated(completion.finishReason) { return .cutOff(hadText: !text.isEmpty) }
        if text.isEmpty { return .empty }
        if isUnterminatedJSONObject(text) { return .cutOff(hadText: true) }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return .malformed
        }
        let missing = missingParts(in: object)
        guard missing.isEmpty else { return .incomplete(missing: missing) }
        guard let summary = decodeSummary(from: text) else { return .malformed }
        return .complete(summary)
    }

    /// True when `text` (fences stripped) opens a JSON object and ends before
    /// closing it — inside a string, an object or an array. A closed object with
    /// trailing text is not unterminated (it is malformed); text that doesn't
    /// start with `{` never is.
    static func isUnterminatedJSONObject(_ text: String) -> Bool {
        let body = stripCodeFences(text)
        guard body.unicodeScalars.first == "{" else { return false }
        var depth = 0, inString = false, escaped = false
        for scalar in body.unicodeScalars {
            if inString {
                if escaped { escaped = false }
                else if scalar == "\\" { escaped = true }
                else if scalar == "\"" { inString = false }
                continue
            }
            switch scalar {
            case "\"": inString = true
            case "{", "[": depth += 1
            case "}", "]":
                depth -= 1
                if depth == 0 { return false }
            default: break
            }
        }
        return true
    }

    /// The prompt's keys this answer object lacks, spelled and ordered as the
    /// prompt has them. `tldr` must be a non-blank string; each other part is
    /// present when it exists with a non-null value under a spelling the decoder
    /// reads (snake_case or camelCase). Lists may be empty and `overview` may be
    /// blank (a ten-second recording).
    private static func missingParts(in object: [String: Any]) -> [String] {
        func present(_ keys: String...) -> Bool {
            keys.contains { key in object[key].map { !($0 is NSNull) } ?? false }
        }
        var missing: [String] = []
        let tldr = (object["tldr"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if tldr.isEmpty { missing.append("tldr") }
        if !present("overview") { missing.append("overview") }
        if !present("action_items", "actionItems") { missing.append("action_items") }
        if !present("per_speaker_highlights", "perSpeakerHighlights") { missing.append("per_speaker_highlights") }
        return missing
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
