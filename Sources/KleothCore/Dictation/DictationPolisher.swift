import Foundation

/// Everything the polish call knows about one dictation besides the words.
public struct DictationContext: Sendable, Equatable {
    /// Bundle id of the app that was frontmost when the chord went down.
    public var appBundleId: String?
    /// Human-readable name of that app.
    public var appName: String?
    /// Scribe's `language_code` (ISO-639-3, e.g. `"rus"`) or nil.
    public var languageCode: String?
    /// Personal-dictionary terms, **already sanitized by the caller** with
    /// `Keyterms.sanitize`. The polisher does not re-sanitize.
    public var dictionary: [String]

    public init(
        appBundleId: String? = nil,
        appName: String? = nil,
        languageCode: String? = nil,
        dictionary: [String] = []
    ) {
        self.appBundleId = appBundleId
        self.appName = appName
        self.languageCode = languageCode
        self.dictionary = dictionary
    }
}

/// The outcome of a polish attempt. Deliberately non-throwing: dictation must
/// always paste *something*, so the raw-transcript fallback is part of the
/// return type rather than an error the call site could forget to catch.
public enum DictationPolishResult: Sendable, Equatable {
    /// The model returned usable, same-language output.
    ///
    /// `language` is the BCP-47 code the model says it wrote. Informational
    /// only: it has already passed the translation guard by the time you see
    /// it, and the log stores Scribe's `language_code` (ISO-639-3, e.g.
    /// `"rus"`), never this value — one source of truth on disk.
    case polished(text: String, language: String?, cost: Double)
    /// Every failure path. `reason` is short and user-facing (it goes on the pill).
    case raw(text: String, reason: String)

    /// The text to insert, whichever branch won.
    public var text: String {
        switch self {
        case let .polished(text, _, _): return text
        case let .raw(text, _): return text
        }
    }

    public var usedRawFallback: Bool {
        if case .raw = self { return true }
        return false
    }

    public var fallbackReason: String? {
        if case let .raw(_, reason) = self { return reason }
        return nil
    }

    /// USD spent on the polish call; 0 for `.raw`.
    public var cost: Double {
        if case let .polished(_, _, cost) = self { return cost }
        return 0
    }

    /// The model-reported language; nil for `.raw`.
    public var language: String? {
        if case let .polished(_, language, _) = self { return language }
        return nil
    }
}

/// One OpenRouter call that turns a raw dictation transcript into the text the
/// user meant to type.
///
/// `Sendable` because `OpenRouterClient` is `Sendable` — do not add
/// `@unchecked`; if this stops compiling, that conformance went missing.
public struct DictationPolisher: Sendable {
    public let client: OpenRouterClient
    public var model: String
    public var timeout: TimeInterval

    public init(
        client: OpenRouterClient,
        model: String = DictationDefaults.polishModel,
        timeout: TimeInterval = DictationDefaults.polishTimeout
    ) {
        self.client = client
        self.model = model
        self.timeout = timeout
    }

    /// Cleans up `rawText`. Never throws: any failure returns
    /// `.raw(text: rawText, reason:)` so the caller always has something to paste.
    ///
    /// An empty (or whitespace-only) input short-circuits without a request.
    public func polish(rawText: String, context: DictationContext) async -> DictationPolishResult {
        let raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .raw(text: "", reason: "Nothing was heard.") }

        let style = AppStyle.classify(bundleId: context.appBundleId)
        let messages = [
            ChatMessage(role: "system", content: DictationPrompt.system),
            ChatMessage(
                role: "user",
                content: DictationPrompt.userContent(raw: raw, context: context, style: style)
            ),
        ]
        // Cyrillic tokenizes roughly 2–3× heavier than Latin, so budget by
        // characters rather than by an assumed 4-chars-per-token ratio.
        let maxTokens = min(8192, max(1024, raw.count / 2 + 512))

        let client = self.client
        let model = self.model
        do {
            let response = try await withTimeout(seconds: timeout) {
                try await client.complete(
                    messages: messages,
                    model: model,
                    responseFormat: .jsonSchema(
                        name: "dictation_text",
                        schemaJSON: DictationPrompt.schemaJSON
                    ),
                    maxTokens: maxTokens,
                    temperature: 0.2
                )
            }

            if Summarizer.isTruncated(response.finishReason) {
                return .raw(text: raw, reason: "Polish was cut off — pasted the raw transcript.")
            }
            guard let decoded = Self.decode(response.content) else {
                return .raw(text: raw, reason: "Polish returned unusable output — pasted the raw transcript.")
            }
            let polished = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)

            // Hallucination guard: the polisher may only shrink or lightly
            // reshape. Anything wildly longer is the model having written an
            // email instead of cleaning one up.
            guard !polished.isEmpty, polished.count <= raw.count * 3 + 200 else {
                return .raw(text: raw, reason: "Polish output looked wrong — pasted the raw transcript.")
            }

            // Translation guard — the reason the schema asks for `language` at
            // all. Scribe's code (ISO-639-3 "rus") and the model's (BCP-47
            // "ru") are compared by NAME via `Summarizer.languageName`, which
            // maps both, so the guard fires only when BOTH resolve and differ;
            // unknown codes never cause a false fallback.
            if let spoken = Summarizer.languageName(for: context.languageCode),
               let written = Summarizer.languageName(for: decoded.language),
               spoken != written {
                return .raw(text: raw, reason: "Polish changed the language — pasted the raw transcript.")
            }

            return .polished(
                text: polished,
                language: decoded.language,
                cost: response.usage?.cost ?? 0
            )
        } catch is KleothTimeoutError {
            return .raw(text: raw, reason: "Polish timed out — pasted the raw transcript.")
        } catch is CancellationError {
            return .raw(text: raw, reason: "Cancelled.")
        } catch {
            return .raw(
                text: raw,
                reason: "Polish failed (\(error.localizedDescription)) — pasted the raw transcript."
            )
        }
    }

    // MARK: - Response parsing

    /// The shape the model is asked for.
    struct PolishedPayload: Decodable {
        let text: String
        let language: String?
    }

    /// Strips any code fences (some providers wrap JSON even under a strict
    /// schema) and decodes `{text, language?}`. Returns nil on any failure.
    static func decode(_ content: String) -> PolishedPayload? {
        let cleaned = Summarizer.stripCodeFences(content)
        guard !cleaned.isEmpty, let data = cleaned.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PolishedPayload.self, from: data)
    }
}
