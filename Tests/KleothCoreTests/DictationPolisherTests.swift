import Testing
import Foundation
@testable import KleothCore

/// A transport that never answers in time — used to prove `withTimeout` actually
/// fires on the polish leg (`URLSessionTransport`'s own 1200 s request timeout
/// never would).
private final class SlowMockTransport: HTTPTransport, @unchecked Sendable {
    let delay: TimeInterval

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        let response = MockTransport.httpResponse(url: request.url!, statusCode: 200)
        return (Data("{}".utf8), response)
    }

    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

@Suite struct DictationPolisherTests {
    // MARK: - Builders

    /// Wraps `content` as an OpenRouter chat-completions response envelope.
    static func envelope(content: String, cost: Double? = nil, finishReason: String? = nil) -> String {
        let escaped = escapeForJSONString(content)
        let finish = finishReason.map { ", \"finish_reason\": \"\($0)\"" } ?? ""
        let usage = cost.map { ", \"usage\": { \"cost\": \($0) }" } ?? ""
        return "{ \"choices\": [ { \"message\": { \"role\": \"assistant\", \"content\": \"\(escaped)\" }\(finish) } ]\(usage) }"
    }

    static func escapeForJSONString(_ raw: String) -> String {
        var out = ""
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    static func polisher(_ transport: HTTPTransport, timeout: TimeInterval = 8) -> DictationPolisher {
        DictationPolisher(
            client: OpenRouterClient(apiKey: "test-key", transport: transport),
            timeout: timeout
        )
    }

    static func requestBody(_ transport: MockTransport, at index: Int = 0) throws -> [String: Any] {
        let request = transport.recordedRequests[index]
        let body = try #require(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: body)
        return try #require(object as? [String: Any])
    }

    // MARK: - Happy path

    @Test func happyPathDecodesPolished() async throws {
        let payload = #"{"text":"Ship the fix today.","language":"en"}"#
        let transport = MockTransport(json: Self.envelope(content: payload, cost: 0.00004))
        let result = await Self.polisher(transport).polish(
            rawText: "um so ship the the fix today",
            context: DictationContext(languageCode: "eng")
        )

        #expect(result == .polished(text: "Ship the fix today.", language: "en", cost: 0.00004))
        #expect(result.text == "Ship the fix today.")
        #expect(!result.usedRawFallback)
        #expect(result.fallbackReason == nil)
        #expect(transport.callCount == 1)
    }

    @Test func fencedJSONStillDecodes() async {
        let fenced = "```json\n" + #"{"text":"Ship it.","language":"en"}"# + "\n```"
        let transport = MockTransport(json: Self.envelope(content: fenced))
        let result = await Self.polisher(transport).polish(rawText: "uh ship it", context: DictationContext())

        #expect(result.text == "Ship it.")
        #expect(!result.usedRawFallback)
    }

    // MARK: - Fallbacks

    @Test func finishReasonLengthFallsBackToRawWithoutRetry() async {
        let payload = #"{"text":"Ship the fix","language":"en"}"#
        let transport = MockTransport(json: Self.envelope(content: payload, finishReason: "length"))
        let result = await Self.polisher(transport).polish(rawText: "ship the fix", context: DictationContext())

        #expect(result == .raw(text: "ship the fix", reason: "Polish was cut off — pasted the raw transcript."))
        // The polisher never retries: dictation is interactive, raw is fine.
        #expect(transport.callCount == 1)
    }

    @Test func postResponseFallbacksCarryTheBilledCost() async {
        // These three fallbacks are decided after a successful, billed response,
        // so the day file must not record `polish_cost: 0` for them.
        let truncated = MockTransport(
            json: Self.envelope(content: #"{"text":"Ship the fix","language":"en"}"#, cost: 0.0031, finishReason: "length")
        )
        let a = await Self.polisher(truncated).polish(rawText: "ship the fix", context: DictationContext())
        #expect(a == .raw(text: "ship the fix", reason: "Polish was cut off — pasted the raw transcript.", cost: 0.0031))
        #expect(a.cost == 0.0031)
        #expect(a.usedRawFallback)

        let prose = MockTransport(json: Self.envelope(content: "Sure! Here is your cleaned text.", cost: 0.0002))
        let b = await Self.polisher(prose).polish(rawText: "hello there", context: DictationContext())
        #expect(b.usedRawFallback)
        #expect(b.cost == 0.0002)

        let translated = MockTransport(
            json: Self.envelope(content: #"{"text":"We need to deploy this today.","language":"en"}"#, cost: 0.0005)
        )
        let c = await Self.polisher(translated).polish(
            rawText: "нам нужно задеплоить это сегодня",
            context: DictationContext(languageCode: "rus")
        )
        #expect(c.usedRawFallback)
        #expect(c.cost == 0.0005)

        // Nothing was billed when the request never completed.
        let failed = MockTransport(json: "{\"error\":\"boom\"}", statusCode: 500)
        let d = await Self.polisher(failed).polish(rawText: "hello there", context: DictationContext())
        #expect(d.cost == 0)
        #expect(DictationPolishResult.raw(text: "x", reason: "y") == .raw(text: "x", reason: "y", cost: 0))
    }

    @Test func http500FallsBackToRaw() async {
        let transport = MockTransport(json: "{\"error\":\"boom\"}", statusCode: 500)
        var polisher = Self.polisher(transport)
        polisher.fallbackModel = nil   // the second-model path has its own tests below
        let result = await polisher.polish(rawText: "hello there", context: DictationContext())

        #expect(result.usedRawFallback)
        #expect(result.text == "hello there")
        // Status only — the provider body never reaches the pill / day file.
        #expect(result == .raw(text: "hello there", reason: "Polish failed (OpenRouter returned HTTP 500) — pasted the raw transcript."))
        // A 500 is not a parameter-routing symptom, so there is no relaxed retry.
        #expect(transport.callCount == 1)
    }

    @Test func failureReasonIsBoundedEvenForLongProviderBodies() async {
        let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        // A ~550-char guardrail body like the live `zdr-violation-by-account` one, on both attempts.
        let body = "{\"error\":{\"message\":\"0 endpoints out of 1 requested are available matching your guardrail restrictions and data policy. "
            + String(repeating: "We removed them for the following reasons. ", count: 10) + "\",\"code\":404}}"
        #expect(body.count > 500)
        let transport = MockTransport(outcomes: [
            .success(Data(body.utf8), MockTransport.httpResponse(url: url, statusCode: 404)),
            .success(Data(body.utf8), MockTransport.httpResponse(url: url, statusCode: 404)),
        ])

        var polisher = Self.polisher(transport)
        polisher.fallbackModel = nil   // the second-model path has its own tests below
        let result = await polisher.polish(rawText: "hello there", context: DictationContext())

        #expect(result == .raw(text: "hello there", reason: "Polish failed (OpenRouter returned HTTP 404) — pasted the raw transcript."))
        #expect(transport.callCount == 2)

        // Non-HTTP errors are clipped rather than dropped.
        struct Chatty: LocalizedError {
            var errorDescription: String? { String(repeating: "x", count: 400) }
        }
        let clipped = DictationPolisher.shortDescription(of: Chatty())
        #expect(clipped.count == DictationPolisher.maxFailureDetailLength + 1)
        #expect(clipped.hasSuffix("…"))
        #expect(DictationPolisher.shortDescription(of: OpenRouterError.noContent) == "OpenRouter returned an empty response.")
    }

    @Test func proseContentFallsBackToRaw() async {
        let transport = MockTransport(json: Self.envelope(content: "Sure! Here is your cleaned text."))
        let result = await Self.polisher(transport).polish(rawText: "hello there", context: DictationContext())

        #expect(result == .raw(
            text: "hello there",
            reason: "Polish returned unusable output — pasted the raw transcript."
        ))
    }

    @Test func emptyTextFallsBackToRaw() async {
        let transport = MockTransport(json: Self.envelope(content: #"{"text":"   ","language":"en"}"#))
        let result = await Self.polisher(transport).polish(rawText: "hello there", context: DictationContext())

        #expect(result == .raw(
            text: "hello there",
            reason: "Polish output looked wrong — pasted the raw transcript."
        ))
    }

    @Test func tenTimesLongerOutputFallsBackToRaw() async {
        let raw = "write me an email about the outage"
        let hallucinated = String(repeating: "Dear customer, we regret the outage. ", count: 20)
        let transport = MockTransport(
            json: Self.envelope(content: #"{"text":""# + hallucinated + #"","language":"en"}"#)
        )
        #expect(hallucinated.count > raw.count * 3 + 200)

        let result = await Self.polisher(transport).polish(rawText: raw, context: DictationContext())
        #expect(result == .raw(text: raw, reason: "Polish output looked wrong — pasted the raw transcript."))
    }

    @Test func emptyInputMakesNoRequest() async {
        let transport = MockTransport(json: Self.envelope(content: #"{"text":"x","language":"en"}"#))
        let result = await Self.polisher(transport).polish(rawText: "   \n  ", context: DictationContext())

        #expect(result == .raw(text: "", reason: "Nothing was heard."))
        #expect(transport.callCount == 0)
    }

    // MARK: - Request shape

    @Test func http400OnJSONSchemaRetriesRelaxed() async throws {
        let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        let payload = #"{"text":"Ship it.","language":"en"}"#
        let transport = MockTransport(outcomes: [
            .success(Data("{\"error\":\"schema unsupported\"}".utf8),
                     MockTransport.httpResponse(url: url, statusCode: 400)),
            .success(Data(Self.envelope(content: payload).utf8),
                     MockTransport.httpResponse(url: url, statusCode: 200)),
        ])

        let result = await Self.polisher(transport).polish(rawText: "uh ship it", context: DictationContext())

        #expect(result.text == "Ship it.")
        #expect(!result.usedRawFallback)
        #expect(transport.callCount == 2)

        let first = try Self.requestBody(transport, at: 0)
        let firstFormat = try #require(first["response_format"] as? [String: Any])
        #expect(firstFormat["type"] as? String == "json_schema")
        #expect(first["temperature"] as? Double == 0.2)
        #expect(first["reasoning"] != nil)

        // Under `require_parameters: true` every parameter narrows routing, so
        // the retry drops all of them — not just the strict schema. (Live:
        // google/gemini-3.8-flash 404s on `temperature` alone on this account.)
        let second = try Self.requestBody(transport, at: 1)
        let secondFormat = try #require(second["response_format"] as? [String: Any])
        #expect(secondFormat["type"] as? String == "json_object")
        #expect(second["temperature"] == nil)
        #expect(second["reasoning"] == nil)
        let provider = try #require(second["provider"] as? [String: Any])
        #expect(provider["require_parameters"] as? Bool == true)
    }

    @Test func routing404IsRecoveredByTheRelaxedRetry() async throws {
        // The exact live failure: the first body 404s with the ZDR guardrail
        // message; the relaxed body succeeds. The user must get polished text.
        let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        let guardrail = "{\"error\":{\"message\":\"0 endpoints out of 1 requested are available matching your guardrail restrictions and data policy.\",\"code\":404,\"metadata\":{\"reason\":\"zdr-violation-by-account\"}}}"
        let transport = MockTransport(outcomes: [
            .success(Data(guardrail.utf8), MockTransport.httpResponse(url: url, statusCode: 404)),
            .success(Data(Self.envelope(content: #"{"text":"Ship it.","language":"en"}"#, cost: 0.0001).utf8),
                     MockTransport.httpResponse(url: url, statusCode: 200)),
        ])
        var polisher = Self.polisher(transport)
        polisher.model = "google/gemini-3.8-flash"

        let result = await polisher.polish(rawText: "uh ship it", context: DictationContext(languageCode: "eng"))

        #expect(result == .polished(text: "Ship it.", language: "en", cost: 0.0001))
        #expect(transport.callCount == 2)
        let second = try Self.requestBody(transport, at: 1)
        #expect(second["model"] as? String == "google/gemini-3.8-flash")
        #expect(second["temperature"] == nil)
        #expect(second["reasoning"] == nil)
    }

    @Test func requestBodyCarriesTemperatureAndDictationModel() async throws {
        let transport = MockTransport(json: Self.envelope(content: #"{"text":"Ship it.","language":"en"}"#))
        _ = await Self.polisher(transport).polish(
            rawText: "uh ship it",
            context: DictationContext(appBundleId: "com.apple.Terminal", appName: "Terminal")
        )

        let body = try Self.requestBody(transport)
        #expect(body["model"] as? String == DictationDefaults.polishModel)
        #expect(body["model"] as? String == "google/gemini-3.5-flash-lite")
        #expect(body["temperature"] as? Double == 0.2)
        // The default model can think: the polish call caps its reasoning
        // (latency). The summarizer sends `reasoning: .low` only on its one retry
        // after an empty cut-off.
        let reasoning = try #require(body["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "minimal")
        #expect(DictationDefaults.reasoningCappedModels.contains(DictationDefaults.polishModel))

        let provider = try #require(body["provider"] as? [String: Any])
        #expect(provider["require_parameters"] as? Bool == true)

        let format = try #require(body["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schemaWrapper = try #require(format["json_schema"] as? [String: Any])
        #expect(schemaWrapper["name"] as? String == "dictation_text")
        #expect(schemaWrapper["strict"] as? Bool == true)

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == DictationPrompt.system)
        let user = try #require(messages[1]["content"] as? String)
        #expect(user.contains("Target application: Terminal (com.apple.Terminal)"))
        #expect(user.contains("Mode: \(AppStyle.compose.hint)"))   // a terminal is a compose target
        #expect(user.contains("<<<TRANSCRIPT\nuh ship it\nTRANSCRIPT>>>"))
    }

    @Test func reasoningCapIsOmittedForModelsNotMeasured() async throws {
        // Under `require_parameters: true` the `reasoning` key 404s on
        // non-reasoning models (measured on llama-3.3-70b) and slows hybrid
        // ones (deepseek-v4-flash), so a user-picked model outside the
        // allowlist must get a body without the key at all.
        let transport = MockTransport(json: Self.envelope(content: #"{"text":"Ship it.","language":"en"}"#))
        var polisher = Self.polisher(transport)
        polisher.model = "meta-llama/llama-3.3-70b-instruct"
        let result = await polisher.polish(
            rawText: "uh ship it",
            context: DictationContext(appBundleId: "com.apple.Terminal", appName: "Terminal")
        )
        #expect(result == .polished(text: "Ship it.", language: "en", cost: 0))

        let body = try Self.requestBody(transport)
        #expect(body["model"] as? String == "meta-llama/llama-3.3-70b-instruct")
        #expect(body["reasoning"] == nil)
        #expect(DictationPolisher.reasoning(for: "meta-llama/llama-3.3-70b-instruct") == nil)
        #expect(DictationPolisher.reasoning(for: DictationDefaults.polishModel) == OpenRouterReasoning(effort: .minimal))
        #expect(DictationPolisher.reasoning(for: "z-ai/glm-5.3-flash") == .low)
        #expect(DictationPolisher.reasoning(for: "google/gemini-3.8-flash") == .low)
    }

    // MARK: - Fallback model

    @Test func httpFailureOnThePrimaryFallsThroughToTheFallbackModel() async throws {
        // Live shape: an account whose OpenRouter privacy settings block
        // google/* — the primary 404s (and the client's relaxed retry 404s
        // again); the fallback model must still deliver polished text.
        let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        let guardrail = Data("{\"error\":{\"message\":\"0 endpoints out of 1 requested are available matching your guardrail restrictions and data policy.\",\"code\":404}}".utf8)
        let transport = MockTransport(outcomes: [
            .success(guardrail, MockTransport.httpResponse(url: url, statusCode: 404)),
            .success(guardrail, MockTransport.httpResponse(url: url, statusCode: 404)),
            .success(Data(Self.envelope(content: #"{"text":"Ship it.","language":"en"}"#, cost: 0.0002).utf8),
                     MockTransport.httpResponse(url: url, statusCode: 200)),
        ])
        let result = await Self.polisher(transport).polish(rawText: "uh ship it", context: DictationContext(languageCode: "eng"))

        #expect(result == .polished(text: "Ship it.", language: "en", cost: 0.0002))
        #expect(transport.callCount == 3)
        #expect(try Self.requestBody(transport, at: 0)["model"] as? String == DictationDefaults.polishModel)
        #expect(try Self.requestBody(transport, at: 1)["model"] as? String == DictationDefaults.polishModel)
        let third = try Self.requestBody(transport, at: 2)
        #expect(third["model"] as? String == DictationDefaults.fallbackPolishModel)
        // The fallback gets its own reasoning cap, not the primary's.
        #expect((third["reasoning"] as? [String: Any])?["effort"] as? String == "low")
    }

    @Test func fallbackIsNotTriedWhenItIsTheSameModelOrDisabled() async {
        let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        let failing = { MockTransport(outcomes: [
            .success(Data("{}".utf8), MockTransport.httpResponse(url: url, statusCode: 500)),
            .success(Data("{}".utf8), MockTransport.httpResponse(url: url, statusCode: 500)),
            .success(Data("{}".utf8), MockTransport.httpResponse(url: url, statusCode: 500)),
        ]) }

        let same = failing()
        var samePolisher = Self.polisher(same)
        samePolisher.model = "z-ai/glm-5.3-flash"
        samePolisher.fallbackModel = "z-ai/glm-5.3-flash"
        let a = await samePolisher.polish(rawText: "uh ship it", context: DictationContext())
        #expect(a.usedRawFallback)
        #expect(same.callCount == 1)   // 500 is not retried by the client; no second model

        let disabled = failing()
        var disabledPolisher = Self.polisher(disabled)
        disabledPolisher.fallbackModel = nil
        let b = await disabledPolisher.polish(rawText: "uh ship it", context: DictationContext())
        #expect(b.usedRawFallback)
        #expect(disabled.callCount == 1)
    }

    @Test func fallbackIsNotTriedAfterATimeoutOrABadAnswer() async {
        // A timeout has spent the budget; a 200 with unusable content is a
        // model answer, not a routing failure — neither gets a second model.
        let slow = SlowMockTransport(delay: 5)
        let timedOut = await Self.polisher(slow, timeout: 0.2).polish(rawText: "uh ship it", context: DictationContext())
        #expect(timedOut.fallbackReason?.contains("timed out") == true)

        let prose = MockTransport(json: Self.envelope(content: "Sure! Here is the text."))
        let bad = await Self.polisher(prose).polish(rawText: "uh ship it", context: DictationContext())
        #expect(bad.usedRawFallback)
        #expect(prose.callCount == 1)
    }

    @Test func stalledTransportTimesOutPromptly() async {
        let started = Date()
        let result = await Self.polisher(SlowMockTransport(delay: 10), timeout: 0.2)
            .polish(rawText: "hello there", context: DictationContext())
        let elapsed = Date().timeIntervalSince(started)

        #expect(result == .raw(text: "hello there", reason: "Polish timed out — pasted the raw transcript."))
        #expect(elapsed < 2.0)
    }

    // MARK: - Translation guard

    @Test func languageMismatchFallsBackToRaw() async {
        let transport = MockTransport(
            json: Self.envelope(content: #"{"text":"We need to deploy this today.","language":"en"}"#)
        )
        let raw = "нам нужно задеплоить это сегодня"
        let result = await Self.polisher(transport).polish(
            rawText: raw,
            context: DictationContext(languageCode: "rus")
        )

        #expect(result == .raw(text: raw, reason: "Polish changed the language — pasted the raw transcript."))
    }

    @Test func sameLanguageInDifferentCodeFormsIsPolished() async {
        let polishedText = "Нам нужно задеплоить это сегодня."
        let transport = MockTransport(
            json: Self.envelope(content: #"{"text":"Нам нужно задеплоить это сегодня.","language":"ru"}"#)
        )
        let result = await Self.polisher(transport).polish(
            rawText: "ну короче нам нужно задеплоить это сегодня",
            context: DictationContext(languageCode: "rus")
        )

        // Scribe's ISO-639-3 "rus" and the model's BCP-47 "ru" name the same
        // language, so the guard must not fire.
        #expect(result == .polished(text: polishedText, language: "ru", cost: 0))
    }

    @Test func unknownLanguageCodesSkipTheGuard() async {
        // Model reports nothing.
        let noModelLanguage = MockTransport(json: Self.envelope(content: #"{"text":"Ship it.","language":null}"#))
        let a = await Self.polisher(noModelLanguage).polish(
            rawText: "uh ship it",
            context: DictationContext(languageCode: "rus")
        )
        #expect(a == .polished(text: "Ship it.", language: nil, cost: 0))

        // Scribe reports nothing.
        let noScribeLanguage = MockTransport(json: Self.envelope(content: #"{"text":"Ship it.","language":"en"}"#))
        let b = await Self.polisher(noScribeLanguage).polish(
            rawText: "uh ship it",
            context: DictationContext(languageCode: nil)
        )
        #expect(b == .polished(text: "Ship it.", language: "en", cost: 0))

        // Neither code resolves to a name.
        let unknownCodes = MockTransport(json: Self.envelope(content: #"{"text":"Ship it.","language":"xx"}"#))
        let c = await Self.polisher(unknownCodes).polish(
            rawText: "uh ship it",
            context: DictationContext(languageCode: "yy")
        )
        #expect(c == .polished(text: "Ship it.", language: "xx", cost: 0))
    }

    // MARK: - Field context (design 2026-09-24-dictation-context §3.7)

    static let tooLong = "Selection too long to merge — added the dictation after it"

    /// A field context as the policy makes one, its boundary judged from `before`.
    static func field(
        _ placement: DictationPlacement, before: String = "", selection: String = "", after: String = "",
        verdict: DictationFieldContext.SelectionVerdict = .merge
    ) -> DictationFieldContext {
        DictationFieldContext(
            placement: placement, before: before, after: after, selection: selection,
            verdict: verdict, isSingleLine: false, boundary: DictationContextFit.boundary(before: before)
        )
    }

    /// A chat client whose every answer is `content`, billed `cost`.
    static func answering(_ content: String, cost: Double = 0, finishReason: String = "stop") -> MockChatClient {
        MockChatClient(results: [.success(ChatCompletion(
            content: content, usage: ChatUsage(cost: cost), finishReason: finishReason
        ))])
    }

    /// The JSON object the model answers with.
    static func payload(_ text: String, language: String = "en") -> String {
        #"{"text":""# + escapeForJSONString(text) + #"","language":""# + language + #""}"#
    }

    /// The strict schema a call asked for; nil for any other response format.
    static func schema(of call: MockChatClient.Call) -> (name: String, json: String)? {
        guard case let .jsonSchema(name, schemaJSON) = call.responseFormat else { return nil }
        return (name, schemaJSON)
    }

    @Test func fieldContextSwitchesToTheContextPromptAndSchema() async throws {
        // A caret, a merge and a terminal reference: the context system prompt, the context schema
        // under today's name, and the user message rendered for that field.
        let fields = [
            Self.field(.cursor, before: "I looked at the export function and I think the problem is", after: " for now."),
            Self.field(.selection, before: "Let's meet on ", selection: "Monday", after: "."),
            Self.field(.reference, selection: "error: cannot find 'parseMeetingErrors' in scope"),
        ]
        for field in fields {
            let client = Self.answering(Self.payload("Tuesday at 11"), cost: 0.0006)
            let context = DictationContext(appBundleId: "com.apple.dt.Xcode", appName: "Xcode", languageCode: "eng", field: field)
            let result = await DictationPolisher(client: client).polish(rawText: "tuesday at eleven", context: context)
            #expect(result == .polished(text: "Tuesday at 11", language: "en", cost: 0.0006), "\(field.placement)")

            let call = try #require(client.calls.first)
            #expect(call.messages.map(\.role) == ["system", "user"])
            #expect(call.messages.first?.content == DictationPrompt.contextSystem, "\(field.placement)")
            let user = try #require(call.messages.last?.content)
            #expect(user == DictationPrompt.userContent(raw: "tuesday at eleven", context: context, style: .compose))
            #expect(user.contains("\nPlacement: "), "\(field.placement)")
            let schema = try #require(Self.schema(of: call))
            #expect(schema.name == "dictation_text")
            #expect(schema.json == DictationPrompt.contextSchemaJSON, "\(field.placement)")
        }

        // The fallback model gets the same request.
        let client = MockChatClient(results: [
            .failure(OpenRouterError.httpError(status: 404, bodySnippet: "guardrail")),
            .success(ChatCompletion(content: Self.payload("Tuesday at 11"), usage: nil, finishReason: "stop")),
        ])
        let merge = DictationContext(languageCode: "eng", field: fields[1])
        let rescued = await DictationPolisher(client: client).polish(rawText: "tuesday at eleven", context: merge)
        #expect(rescued == .polished(text: "Tuesday at 11", language: "en", cost: 0))
        #expect(client.calls.count == 2)
        #expect(client.calls.last?.model == DictationDefaults.fallbackPolishModel)
        for call in client.calls {
            #expect(call.messages.first?.content == DictationPrompt.contextSystem)
            #expect(call.messages.last?.content == DictationPrompt.userContent(raw: "tuesday at eleven", context: merge, style: .compose))
            #expect(Self.schema(of: call)?.json == DictationPrompt.contextSchemaJSON)
        }
    }

    @Test func noFieldContextSendsTodaysMessages() async throws {
        // Without field context the request is today's: the system prompt and schema whose SHA-256
        // DictationPromptTests pins, today's user message, and today's output budget. (Today's
        // fallback reasons are pinned by the tests above, all of them without a field.)
        let context = DictationContext(
            appBundleId: "com.apple.dt.Xcode", appName: "Xcode", languageCode: "eng", dictionary: ["Kleoth"]
        )
        #expect(context.field == nil)
        let cases: [(raw: String, maxTokens: Int)] = [
            ("um so ship the the fix today", 1_024),               // the floor
            (String(repeating: "a", count: 3_000), 2_012),         // 3,000 / 2 + 512
            (String(repeating: "a", count: 20_000), 8_192),        // the ceiling
        ]
        for (raw, maxTokens) in cases {
            let client = Self.answering(Self.payload("Ship the fix today."))
            let result = await DictationPolisher(client: client).polish(rawText: raw, context: context)
            #expect(result == .polished(text: "Ship the fix today.", language: "en", cost: 0))

            let call = try #require(client.calls.first)
            #expect(call.messages.map(\.role) == ["system", "user"])
            #expect(call.messages.first?.content == DictationPrompt.system)
            let user = try #require(call.messages.last?.content)
            #expect(user == DictationPrompt.userContent(raw: raw, context: context, style: .compose))
            #expect(!user.contains("Placement:"))
            let schema = try #require(Self.schema(of: call))
            #expect(schema.name == "dictation_text")
            #expect(schema.json == DictationPrompt.schemaJSON)
            #expect(call.maxTokens == maxTokens, "\(raw.count) characters")
        }
    }

    @Test func maxTokensAndLengthGuardCountAMergedSelection() async throws {
        // A merge writes the selection back with the dictation, so the output budget and the length
        // guard count the selection's characters too. Nothing else is written back: a caret and a
        // reference keep today's numbers, whatever the text around them.
        let raw = "and log every failed attempt"
        let selection = String(repeating: "Add a retry to the Scribe upload. ", count: 60)
        #expect(raw.count == 28)
        #expect(selection.count == 2_040)
        let merge = DictationContext(field: Self.field(.selection, selection: selection))

        // (28 + 2,040) / 2 + 512 = 1,546 tokens, where the transcript alone gets the floor of 1,024;
        // and the merged answer, 2,069 characters, passes a guard that would refuse it at 284.
        let merged = selection.trimmingCharacters(in: .whitespaces) + " And log every failed attempt."
        let client = Self.answering(Self.payload(merged), cost: 0.0009)
        let result = await DictationPolisher(client: client).polish(rawText: raw, context: merge)
        #expect(result == .polished(text: merged, language: "en", cost: 0.0009))
        #expect(client.calls.first?.maxTokens == 1_546)

        // Clamped as today: 1,024 at least, 8,192 at most.
        let clamped = [("Monday", 1_024), (String(repeating: "Add a retry to the Scribe upload. ", count: 480), 8_192)]
        for (selection, maxTokens) in clamped {
            let client = Self.answering(Self.payload("Tuesday"))
            let context = DictationContext(field: Self.field(.selection, selection: selection))
            _ = await DictationPolisher(client: client).polish(rawText: raw, context: context)
            #expect(client.calls.first?.maxTokens == maxTokens, "\(selection.count) characters")
        }

        // The length guard: 3 × (28 + 2,040) + 200 = 6,404 characters.
        let atLimit = Self.answering(Self.payload(String(repeating: "x", count: 6_404)), cost: 0.0009)
        let fits = await DictationPolisher(client: atLimit).polish(rawText: raw, context: merge)
        #expect(fits.ranModel)
        let over = Self.answering(Self.payload(String(repeating: "x", count: 6_405)), cost: 0.0009)
        let refused = await DictationPolisher(client: over).polish(rawText: raw, context: merge)
        #expect(refused == .raw(
            text: raw, reason: "Polish output looked wrong — added the dictation after the selection.", cost: 0.0009
        ))

        // A caret and a reference: today's budget and today's guard, 3 × 28 + 200 = 284 characters.
        let window = String(selection.prefix(1_500))
        for field in [Self.field(.cursor, before: window), Self.field(.reference, selection: window)] {
            let context = DictationContext(field: field)
            let client = Self.answering(Self.payload(String(repeating: "x", count: 284)))
            let fits = await DictationPolisher(client: client).polish(rawText: raw, context: context)
            #expect(fits.ranModel, "\(field.placement)")
            #expect(client.calls.first?.maxTokens == 1_024, "\(field.placement)")
            let over = Self.answering(Self.payload(String(repeating: "x", count: 285)))
            let refused = await DictationPolisher(client: over).polish(rawText: raw, context: context)
            #expect(refused == .raw(text: raw, reason: "Polish output looked wrong — pasted the raw transcript."), "\(field.placement)")
        }
    }

    @Test func echoingTheContextFallsBack() async throws {
        // Shown the text around the caret, the model copied a sentence of it into its answer: pasted,
        // the sentence would be in the field twice. A fallback, billed (R5).
        let sentence = "Today we parse the whole file before writing anything."   // 45 letters
        let before = "Looked at MeetingStore. \(sentence) "
        let raw = "so we should stream it instead"
        let echo = "\(sentence) So we should stream it instead."
        let echoed = [
            Self.field(.cursor, before: before),
            Self.field(.cursor, before: "Notes: ", after: " \(sentence) It is slow on big files."),
        ]
        for field in echoed {
            let client = Self.answering(Self.payload(echo), cost: 0.0006)
            let result = await DictationPolisher(client: client).polish(rawText: raw, context: DictationContext(field: field))
            #expect(result == .raw(
                text: raw, reason: "Polish repeated text already in the field — pasted the raw transcript.", cost: 0.0006
            ), "\(field.after.isEmpty ? "before" : "after")")
        }

        // The echo guard runs after the length guard and before the translation guard: an answer
        // both too long and echoing gets the length guard's reason, and one that echoes and names
        // another language gets the echo's.
        let caretAfterSentence = DictationContext(languageCode: "eng", field: Self.field(.cursor, before: before))
        let rambling = String(repeating: "\(sentence) ", count: 6) + "So we should stream it instead."
        #expect(rambling.count > raw.count * 3 + 200)
        #expect(DictationContextFit.echoesContext(rambling, before: before, after: "", transcript: raw))
        let overlong = await DictationPolisher(client: Self.answering(Self.payload(rambling), cost: 0.0006))
            .polish(rawText: raw, context: caretAfterSentence)
        #expect(overlong == .raw(text: raw, reason: "Polish output looked wrong — pasted the raw transcript.", cost: 0.0006))
        let relabelled = await DictationPolisher(client: Self.answering(Self.payload(echo, language: "ru"), cost: 0.0006))
            .polish(rawText: raw, context: caretAfterSentence)
        #expect(relabelled == .raw(
            text: raw, reason: "Polish repeated text already in the field — pasted the raw transcript.", cost: 0.0006
        ))

        // A repeat the speaker said is theirs; and without field context there is no field to echo.
        let said = "today we parse the whole file before writing anything so we should stream it instead"
        let spoken = await DictationPolisher(client: Self.answering(Self.payload(echo)))
            .polish(rawText: said, context: DictationContext(field: Self.field(.cursor, before: before)))
        #expect(spoken == .polished(text: echo, language: "en", cost: 0))
        let plain = await DictationPolisher(client: Self.answering(Self.payload(echo)))
            .polish(rawText: raw, context: DictationContext())
        #expect(plain == .polished(text: echo, language: "en", cost: 0))

        // A merge writes the selection back, so the selection's own words are no echo, even where the
        // field repeats them before it. The same answer at a caret after that text is one.
        let chunks = "and then write the output in chunks"
        let continued = "Today we parse the whole file before writing anything, and then write the output in chunks."
        let merge = Self.field(.selection, before: before, selection: sentence)
        let merged = await DictationPolisher(client: Self.answering(Self.payload(continued)))
            .polish(rawText: chunks, context: DictationContext(field: merge))
        #expect(merged == .polished(text: continued, language: "en", cost: 0))
        let caret = await DictationPolisher(client: Self.answering(Self.payload(continued)))
            .polish(rawText: chunks, context: DictationContext(field: Self.field(.cursor, before: before)))
        #expect(caret == .raw(text: chunks, reason: "Polish repeated text already in the field — pasted the raw transcript."))

        // Copying BEFORE past what the selection holds is an echo for a merge too.
        let streamIt = DictationContext(field: Self.field(.selection, before: before, selection: "Stream it."))
        let copied = await DictationPolisher(client: Self.answering(Self.payload("\(sentence) Stream it, and add a test."), cost: 0.0006))
            .polish(rawText: "and add a test", context: streamIt)
        #expect(copied == .raw(
            text: "and add a test",
            reason: "Polish repeated text already in the field — added the dictation after the selection.", cost: 0.0006
        ))
    }

    @Test func selectionFallbacksSayTheDictationWasAddedAfter() async {
        // A selection being merged, or appended (the prompt gets a caret at its end that keeps the
        // `.append` verdict): a failed polish puts the selection back with the raw dictation after it,
        // and every reason says so. "Cancelled." and "Nothing was heard." name no paste and stay.
        let raw = "и логируй каждую неудачную попытку"
        let merged = "Add a retry to the Scribe upload. И логируй каждую неудачную попытку."
        let fields = [
            Self.field(.selection, selection: "Add a retry to the Scribe upload."),
            Self.field(.cursor, before: "Add a retry to the Scribe upload.", verdict: .append(Self.tooLong)),
        ]
        for field in fields {
            let context = DictationContext(languageCode: "rus", field: field)
            let cases: [(client: MockChatClient, cause: String, cost: Double)] = [
                (Self.answering(Self.payload(merged, language: "ru"), cost: 0.0003, finishReason: "length"),
                 "Polish was cut off", 0.0003),
                (Self.answering("Sure! Here is the merged text.", cost: 0.0002), "Polish returned unusable output", 0.0002),
                (Self.answering(Self.payload(String(repeating: "Add a retry. ", count: 100), language: "ru"), cost: 0.0004),
                 "Polish output looked wrong", 0.0004),
                (Self.answering(Self.payload(merged, language: "en"), cost: 0.0005), "Polish changed the language", 0.0005),
                (MockChatClient(results: [.failure(OpenRouterError.httpError(status: 503, bodySnippet: "busy"))]),
                 "Polish failed (OpenRouter returned HTTP 503)", 0),
            ]
            for (client, cause, cost) in cases {
                let result = await DictationPolisher(client: client, fallbackModel: nil).polish(rawText: raw, context: context)
                #expect(result == .raw(
                    text: raw, reason: "\(cause) — added the dictation after the selection.", cost: cost
                ), "\(field.placement) \(cause)")
            }
            let slow = await Self.polisher(SlowMockTransport(delay: 5), timeout: 0.2).polish(rawText: raw, context: context)
            #expect(slow == .raw(text: raw, reason: "Polish timed out — added the dictation after the selection."))

            let cancelled = await DictationPolisher(client: MockChatClient(results: [.failure(CancellationError())]))
                .polish(rawText: raw, context: context)
            #expect(cancelled == .raw(text: raw, reason: "Cancelled."))
            let silent = await DictationPolisher(client: Self.answering(Self.payload(merged, language: "ru")))
                .polish(rawText: " \n ", context: context)
            #expect(silent == .raw(text: "", reason: "Nothing was heard."))
        }

        // A caret and a reference paste the raw transcript, as today.
        for field in [Self.field(.cursor, before: "Add a retry to the Scribe upload."), Self.field(.reference, selection: "upload failed")] {
            let result = await DictationPolisher(client: Self.answering("Sure!", cost: 0.0002))
                .polish(rawText: raw, context: DictationContext(languageCode: "rus", field: field))
            #expect(result == .raw(
                text: raw, reason: "Polish returned unusable output — pasted the raw transcript.", cost: 0.0002
            ), "\(field.placement)")
        }
    }

    @Test func translationGuardComparesTheDictatedLanguage() async throws {
        // A Russian dictation merged into an English selection: the result is mostly English, but
        // `language` names the dictated words' language — what the context schema asks for — and the
        // guard compares that with Scribe's, as it always has.
        let raw = "и логируй каждую неудачную попытку"
        let merged = "Add a retry to the Scribe upload. И логируй каждую неудачную попытку."
        let merge = DictationContext(languageCode: "rus", field: Self.field(.selection, selection: "Add a retry to the Scribe upload."))
        let client = Self.answering(Self.payload(merged, language: "ru"), cost: 0.0006)
        let result = await DictationPolisher(client: client).polish(rawText: raw, context: merge)
        #expect(result == .polished(text: merged, language: "ru", cost: 0.0006))
        let schema = try #require(client.calls.first.flatMap(Self.schema(of:)))
        #expect(schema.json.contains("the language of the dictated words"))

        // Naming the selection's language instead: the language changed.
        let selectionsLanguage = await DictationPolisher(client: Self.answering(Self.payload(merged, language: "en"), cost: 0.0006))
            .polish(rawText: raw, context: merge)
        #expect(selectionsLanguage == .raw(
            text: raw, reason: "Polish changed the language — added the dictation after the selection.", cost: 0.0006
        ))

        // At a caret, the same comparison, with today's wording.
        let caret = DictationContext(languageCode: "rus", field: Self.field(.cursor, before: "Add a retry to the Scribe upload."))
        let dictated = "И логируй каждую неудачную попытку."
        let kept = await DictationPolisher(client: Self.answering(Self.payload(dictated, language: "ru")))
            .polish(rawText: raw, context: caret)
        #expect(kept == .polished(text: dictated, language: "ru", cost: 0))
        let translated = await DictationPolisher(client: Self.answering(Self.payload("And log every failed attempt.", language: "en")))
            .polish(rawText: raw, context: caret)
        #expect(translated == .raw(text: raw, reason: "Polish changed the language — pasted the raw transcript."))
    }

    @Test func emptyMergeAnswerFallsBack() async {
        // A merge's answer replaces the selection, so an empty one would delete it. The polisher
        // refuses an empty answer on every path, which is why `DictationInsertionPlan` never gets
        // `.polished("")` for a merge.
        let raw = "and log every failed attempt"
        let merge = DictationContext(field: Self.field(.selection, before: "Plan: ", selection: "Add a retry to the Scribe upload."))
        for answer in ["", "  \n\t "] {
            let client = Self.answering(Self.payload(answer), cost: 0.0004)
            let result = await DictationPolisher(client: client).polish(rawText: raw, context: merge)
            #expect(result == .raw(
                text: raw, reason: "Polish output looked wrong — added the dictation after the selection.", cost: 0.0004
            ), "\(answer.debugDescription)")
        }
    }

    @Test func policyContextIsConvertedToThePromptContext() async throws {
        // A caller passing the policy's own context gets what `promptContext(providerSupportsContext:)`
        // hands over. An appended selection reaches the model as a caret at its end — the text
        // before it ends with the selection, and there is no SELECTION block — is not written back,
        // and still says the dictation went after the selection when the polish fails.
        let raw = "so it streams the file"
        // Too long to merge, as its verdict says, and long enough that counting it would lift the
        // output budget far over the floor: (22 + 4,026) / 2 + 512 = 2,536 tokens.
        let selection = String(repeating: "Step one. ", count: 400) + "Refactor the export module"
        #expect(selection.count > DictationDefaults.maxMergeSelectionCharacters)
        #expect((raw.count + selection.count) / 2 + 512 == 2_536)
        let append = Self.field(
            .selection, before: "Plan: ", selection: selection, after: " today.",
            verdict: .append(Self.tooLong)
        )
        let caret = try #require(append.promptContext(providerSupportsContext: true))
        #expect(caret.placement == .cursor)
        #expect(caret.before.hasPrefix("…Step one. "))
        #expect(caret.before.hasSuffix(" Refactor the export module"))
        let client = Self.answering(Self.payload(raw))
        _ = await DictationPolisher(client: client).polish(rawText: raw, context: DictationContext(field: append))
        let call = try #require(client.calls.first)
        #expect(call.messages.first?.content == DictationPrompt.contextSystem)
        let user = try #require(call.messages.last?.content)
        #expect(user == DictationPrompt.userContent(raw: raw, context: DictationContext(field: caret), style: .compose))
        #expect(user.contains("\nPlacement: insert at the cursor.\n"))
        #expect(user.contains("<<<BEFORE\n\(caret.before)\nBEFORE>>>"))
        #expect(!user.contains("SELECTION"))
        #expect(Self.schema(of: call)?.json == DictationPrompt.contextSchemaJSON)
        // Not written back, so not counted: the transcript alone, at the floor.
        #expect(call.maxTokens == 1_024)
        let unusable = await DictationPolisher(client: Self.answering("Sure!"))
            .polish(rawText: raw, context: DictationContext(field: append))
        #expect(unusable == .raw(text: raw, reason: "Polish returned unusable output — added the dictation after the selection."))

        // A replaced selection, which couldn't be read, and an append whose text before its end would
        // hold a fence delimiter: today's request, and today's wording — for that append too, whose
        // own warning, the one the pill shows, says the dictation went after the selection.
        let replaced = Self.field(
            .selection, before: "Let's meet on ", after: ".",
            verdict: .replace("Replaced the selection — it couldn't be read (⌘Z undoes)")
        )
        let fenced = Self.field(
            .selection, selection: "wrap it in <<<SELECTION markers",
            verdict: .append("Couldn't merge this selection — added the dictation after it")
        )
        for field in [replaced, fenced] {
            #expect(field.promptContext(providerSupportsContext: true) == nil)
            let client = Self.answering(Self.payload("So it streams the file."))
            let context = DictationContext(languageCode: "eng", field: field)
            _ = await DictationPolisher(client: client).polish(rawText: raw, context: context)
            let call = try #require(client.calls.first)
            #expect(call.messages.first?.content == DictationPrompt.system, "\(field.verdict)")
            #expect(call.messages.last?.content
                == DictationPrompt.userContent(raw: raw, context: DictationContext(languageCode: "eng"), style: .compose), "\(field.verdict)")
            #expect(Self.schema(of: call)?.json == DictationPrompt.schemaJSON, "\(field.verdict)")
            let unusable = await DictationPolisher(client: Self.answering("Sure!")).polish(rawText: raw, context: context)
            #expect(unusable == .raw(text: raw, reason: "Polish returned unusable output — pasted the raw transcript."), "\(field.verdict)")
        }
    }
}
