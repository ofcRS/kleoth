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
    /// The text already in the field the dictation goes into, as
    /// ``DictationFieldContext/promptContext(providerSupportsContext:)`` hands it to the prompt;
    /// nil sends today's request byte for byte. It comes from ``DictationContextPolicy`` through
    /// that call, so its text never contains a fence delimiter. ``DictationPolisher`` passes it
    /// through that call once more, which leaves a prompt context as it is and converts a
    /// policy's own.
    public var field: DictationFieldContext? = nil

    public init(
        appBundleId: String? = nil,
        appName: String? = nil,
        languageCode: String? = nil,
        dictionary: [String] = [],
        field: DictationFieldContext? = nil
    ) {
        self.appBundleId = appBundleId
        self.appName = appName
        self.languageCode = languageCode
        self.dictionary = dictionary
        self.field = field
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
    ///
    /// `cost` is what the failed attempt still billed: the fallbacks for
    /// truncation, undecodable content and the length, echo and translation
    /// guards are decided AFTER a successful, fully billed OpenRouter
    /// response, and the day file must not claim those were free. It stays 0
    /// for the no-key, timeout, cancellation, HTTP-error and pre-request
    /// short-circuit paths.
    case raw(text: String, reason: String, cost: Double = 0)
    /// The controller decided not to call the model at all (`PolishGate`:
    /// a chat app, or fewer than `DictationDefaults.minimumWordsToPolish`
    /// words). Not a fallback — nothing failed, no warning, no cost — so
    /// `usedRawFallback` stays false and the log row carries no `polish_model`.
    /// `DictationPolisher` never produces this case.
    case skipped(text: String, reason: String)

    /// The text to insert, whichever branch won.
    public var text: String {
        switch self {
        case let .polished(text, _, _): return text
        case let .raw(text, _, _): return text
        case let .skipped(text, _): return text
        }
    }

    public var usedRawFallback: Bool {
        if case .raw = self { return true }
        return false
    }

    /// True only when a model actually rewrote the text.
    public var ranModel: Bool {
        if case .polished = self { return true }
        return false
    }

    public var fallbackReason: String? {
        if case let .raw(_, reason, _) = self { return reason }
        return nil
    }

    /// USD the polish call billed — for `.raw` too, when the fallback was
    /// decided after a billed response (see ``raw(text:reason:cost:)``).
    public var cost: Double {
        switch self {
        case let .polished(_, _, cost): return cost
        case let .raw(_, _, cost): return cost
        case .skipped: return 0
        }
    }

    /// The model-reported language; nil for `.raw`.
    public var language: String? {
        if case let .polished(_, language, _) = self { return language }
        return nil
    }
}

/// One chat completion that turns a raw dictation transcript into the text the
/// user meant to type.
///
/// `Sendable` because `ChatCompleting` refines `Sendable` — do not add
/// `@unchecked`; if this stops compiling, that conformance went missing.
public struct DictationPolisher: Sendable {
    public let client: any ChatCompleting
    public var model: String
    public var timeout: TimeInterval
    /// Explicit `reasoning` cap for this polisher; nil → the per-model
    /// allowlist in `DictationDefaults.reasoningCappedModels` decides.
    /// Used by the `dictate` benchmark to measure a cap on any model.
    public var reasoningOverride: OpenRouterReasoning?
    /// Model tried once more when `model` fails with an HTTP error and at
    /// least `DictationDefaults.minimumFallbackBudget` of `timeout` remains.
    /// nil disables the second attempt. Never used after a timeout (the
    /// budget is spent) or a cancellation.
    public var fallbackModel: String?

    public init(
        client: any ChatCompleting,
        model: String = DictationDefaults.polishModel,
        timeout: TimeInterval = DictationDefaults.polishTimeout,
        reasoningOverride: OpenRouterReasoning? = nil,
        fallbackModel: String? = DictationDefaults.fallbackPolishModel
    ) {
        self.client = client
        self.model = model
        self.timeout = timeout
        self.reasoningOverride = reasoningOverride
        self.fallbackModel = fallbackModel
    }

    /// Cleans up `rawText`. Never throws: any failure returns
    /// `.raw(text: rawText, reason:)` so the caller always has something to paste.
    ///
    /// An empty (or whitespace-only) input short-circuits without a request.
    ///
    /// With `context.field` the request carries the text already in the field
    /// (design 2026-09-24-dictation-context §3.7), and every fallback reason
    /// that names a paste ends with what the paste does instead (the field's
    /// ``DictationFieldContext/fallbackConsequence``). Without one, the request
    /// and every reason are today's, byte for byte.
    public func polish(rawText: String, context: DictationContext) async -> DictationPolishResult {
        let raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .raw(text: "", reason: "Nothing was heard.") }

        // A caller passing a field has decided the provider takes context, so
        // the field goes through `promptContext` here too: a prompt context
        // comes back unchanged, and a policy's own is converted as the caller
        // should have — an appended selection to a caret at its end, a replaced
        // one (or an append whose text would hold a fence delimiter) to none,
        // which sends today's request. After this a selection is always a merge.
        var context = context
        context.field = context.field?.promptContext(providerSupportsContext: true)

        let started = ContinuousClock.now
        let primary = await attempt(model: model, raw: raw, context: context, budget: timeout)
        guard primary.httpFailure,
              let fallback = fallbackModel, fallback != model else {
            return primary.result
        }
        // The primary died fast with an HTTP error (guardrail 404, 429, 5xx):
        // spend what is left of the budget on the fallback model rather than
        // pasting raw text. Nothing was billed for the failed attempt.
        let elapsed = started.duration(to: .now)
        let remaining = timeout - Double(elapsed.components.seconds)
            - Double(elapsed.components.attoseconds) / 1e18
        guard remaining >= DictationDefaults.minimumFallbackBudget else { return primary.result }
        let second = await attempt(model: fallback, raw: raw, context: context, budget: remaining)
        return second.result
    }

    /// One polish request against `model`. `httpFailure` is true only when the
    /// request itself failed with an `OpenRouterError.httpError` (after the
    /// client's own relaxed retry) — the one case a different model can rescue.
    ///
    /// What the field context changes — the prompt and schema, the output
    /// budget, the guards, the fallback wording — is settled at the top, so one
    /// request-and-guards sequence serves calls with and without it.
    private func attempt(
        model: String, raw: String, context: DictationContext, budget: TimeInterval
    ) async -> (result: DictationPolishResult, httpFailure: Bool) {
        let client = self.client
        let field = context.field
        let style = AppStyle.classify(bundleId: context.appBundleId)
        let messages = [
            ChatMessage(role: "system", content: field == nil ? DictationPrompt.system : DictationPrompt.contextSystem),
            ChatMessage(
                role: "user",
                content: DictationPrompt.userContent(raw: raw, context: context, style: style)
            ),
        ]
        let schemaJSON = field == nil ? DictationPrompt.schemaJSON : DictationPrompt.contextSchemaJSON
        // A merge writes the selection back with the dictation, so the output
        // budget and the length guard count its characters too. Nothing else is
        // written back (a caret's text and a terminal reference are only read),
        // so without a merge both are today's.
        let selectionCount = field.map { $0.placement == .selection ? $0.selection.count : 0 } ?? 0
        // Cyrillic tokenizes roughly 2–3× heavier than Latin, so budget by
        // characters rather than by an assumed 4-chars-per-token ratio.
        let maxTokens = min(8192, max(1024, (raw.count + selectionCount) / 2 + 512))
        // What the paste does instead; it ends every reason that names a paste.
        let consequence = field?.fallbackConsequence ?? "pasted the raw transcript."
        do {
            let response = try await withTimeout(seconds: budget) {
                try await client.complete(
                    messages: messages,
                    model: model,
                    responseFormat: .jsonSchema(
                        name: "dictation_text",
                        schemaJSON: schemaJSON
                    ),
                    maxTokens: maxTokens,
                    temperature: 0.2,
                    reasoning: reasoningOverride ?? Self.reasoning(for: model)
                )
            }

            // From here on the call has been billed, so every fallback carries
            // the cost OpenRouter reported.
            let billed = response.usage?.cost ?? 0

            if Summarizer.isTruncated(response.finishReason) {
                return (.raw(text: raw, reason: "Polish was cut off — \(consequence)", cost: billed), false)
            }
            guard let decoded = Self.decode(response.content) else {
                return (.raw(
                    text: raw,
                    reason: "Polish returned unusable output — \(consequence)",
                    cost: billed
                ), false)
            }
            let polished = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)

            // Hallucination guard: the polisher may only shrink or lightly
            // reshape. Anything wildly longer is the model having written an
            // email instead of cleaning one up. Nothing at all is refused too:
            // a merge's answer replaces the selection, so it would delete it.
            guard !polished.isEmpty, polished.count <= (raw.count + selectionCount) * 3 + 200 else {
                return (.raw(text: raw, reason: "Polish output looked wrong — \(consequence)", cost: billed), false)
            }

            // Echo guard (R5): shown the text around the caret, the model can
            // copy a sentence of it into the answer, and the paste would then put
            // that sentence in the field twice. A merge writes its selection back,
            // so the selection's words are the answer's own, even where the field
            // repeats them before or after it.
            if let field, DictationContextFit.echoesContext(
                polished, before: field.before, after: field.after,
                transcript: field.placement == .selection ? raw + "\n" + field.selection : raw
            ) {
                return (.raw(text: raw, reason: "Polish repeated text already in the field — \(consequence)", cost: billed), false)
            }

            // Translation guard — the reason the schema asks for `language` at
            // all. Scribe's code (ISO-639-3 "rus") and the model's (BCP-47
            // "ru") are compared by NAME via `Summarizer.languageName`, which
            // maps both, so the guard fires only when BOTH resolve and differ;
            // unknown codes never cause a false fallback. With field context the
            // schema asks for the dictated words' language, so a merge that is
            // mostly the selection's other language still compares like for like.
            if let spoken = Summarizer.languageName(for: context.languageCode),
               let written = Summarizer.languageName(for: decoded.language),
               spoken != written {
                return (.raw(text: raw, reason: "Polish changed the language — \(consequence)", cost: billed), false)
            }

            return (.polished(text: polished, language: decoded.language, cost: billed), false)
        } catch is KleothTimeoutError {
            return (.raw(text: raw, reason: "Polish timed out — \(consequence)"), false)
        } catch is CancellationError {
            return (.raw(text: raw, reason: "Cancelled."), false)
        } catch {
            let isHTTP: Bool
            if case OpenRouterError.httpError = error { isHTTP = true } else { isHTTP = false }
            return (.raw(
                text: raw,
                reason: "Polish failed (\(Self.shortDescription(of: error))) — \(consequence)"
            ), isHTTP)
        }
    }

    // MARK: - Failure wording

    /// Longest failure detail allowed into a `.raw` reason.
    static let maxFailureDetailLength = 120

    /// A bounded, user-facing description of a polish error. The reason lands
    /// on the pill AND in the day file as `fallback_reason`, so an HTTP error
    /// is reduced to its status (the up-to-500-char provider body stays in the
    /// thrown `OpenRouterError` for logs) and anything else is clipped to
    /// ``maxFailureDetailLength`` characters.
    static func shortDescription(of error: Error) -> String {
        if case let OpenRouterError.httpError(status, _) = error {
            return "OpenRouter returned HTTP \(status)"
        }
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > maxFailureDetailLength else { return text }
        return String(text.prefix(maxFailureDetailLength)) + "…"
    }

    // MARK: - Request shaping

    /// The `reasoning` cap for `model`, or nil (key omitted) for every model
    /// not in `DictationDefaults.reasoningCappedModels`. On the default model
    /// this cut polish latency from a mean 8.4 s (one run over the 8 s budget)
    /// to 3.4 s with identical output; on other models it can slow things
    /// down, or 404 on the first attempt (`OpenRouterClient.complete` then
    /// retries without it, costing a round trip) — see the measurements on
    /// `reasoningCappedModels`.
    static func reasoning(for model: String) -> OpenRouterReasoning? {
        DictationDefaults.reasoningCaps[model].map { OpenRouterReasoning(effort: $0) }
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
