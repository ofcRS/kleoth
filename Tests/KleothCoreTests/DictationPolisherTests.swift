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
        let result = await Self.polisher(transport).polish(rawText: "hello there", context: DictationContext())

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

        let result = await Self.polisher(transport).polish(rawText: "hello there", context: DictationContext())

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
        #expect(body["model"] as? String == "z-ai/glm-5.3-flash")
        #expect(body["temperature"] as? Double == 0.2)
        // The default model is a reasoning model: the polish call caps its
        // thinking (latency). The summarizer never sends this key.
        let reasoning = try #require(body["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "low")
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
        #expect(user.contains(AppStyle.code.hint))
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
        #expect(DictationPolisher.reasoning(for: DictationDefaults.polishModel) == .low)
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
}
