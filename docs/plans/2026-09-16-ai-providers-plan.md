# AI Providers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let meeting summaries and dictation polish run on the user's installed Claude Code or Codex CLI, a local OpenAI-compatible server (Ollama / LM Studio), or Apple's on-device model, with OpenRouter as one option among five and auto-detection on a fresh install.

**Architecture:** One `ChatCompleting` protocol replaces the concrete `OpenRouterClient` behind `Summarizer` and `DictationPolisher`. Four adapters implement it: the generalized OpenAI-compatible HTTP client, two `Process`-based CLI adapters (Claude Code, Codex) and a Foundation Models adapter in the app package. A pure `ProviderResolver` picks the provider per task from a detector snapshot; `ProviderFactory` builds the summarizer/polisher; `AppConfig` and the CLIs call the factory instead of gating on an OpenRouter key.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM, swift-testing (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`), Foundation `Process`, FoundationModels (macOS 26, weak-linked).

**Spec:** `docs/plans/2026-09-15-ai-providers.md` — read it first; §1 has the measured facts, §3 the contract, §6 the error copy.

## Global Constraints

- Root package floor is macOS 13; the app package floor is macOS 14.4. FoundationModels code lives only in the app package, behind `#if canImport(FoundationModels)` + `if #available(macOS 26, *)`, and the framework is weak-linked.
- No new package dependencies.
- Every stored key is snake_case and acronym-free: `ai_provider`, `local_server_url`, `local_server_key`, `ai_models`, `summary_provider`, `polish_provider`.
- Never print, log or commit an API key. Tests use the literal `"test-key"`.
- Costs recorded for every backend except OpenRouter are 0 (`ChatUsage.cost == nil`).
- Claude Code is always spawned with `-p --output-format json --tools "" --no-session-persistence --setting-sources "" --strict-mcp-config --mcp-config {"mcpServers":{}} --system-prompt <system>` and the prompt on **stdin** (measured: 1.1k input tokens, 1.7 s; without isolation 154k tokens).
- Codex is always spawned with `exec --json --skip-git-repo-check -s read-only --ephemeral --color never -C <tmp dir>` and the prompt on stdin (`-`). Model is optional (`-m` only when non-empty; `gpt-5-mini` is refused on ChatGPT accounts).
- Auto order: local server → Claude Code → Codex → OpenRouter → Apple on-device. Codex supports summaries only; Apple supports dictation only.
- Run the core suite with `swift test` from the repo root (≈354 tests green before this work); build the app with `swift build --package-path app`. Add a KleothCore source file → delete `app/.build/arm64-apple-macosx/debug/description.json` before the next app build (SwiftPM cache gotcha).
- Commit after every task with the message given in its last step. Never `git add -A`; add the files named in the task.
- Code style: doc comments on every public type, `// MARK:` sections, no force unwraps outside tests.

---

### Task 1: The `ChatCompleting` seam

**Files:**
- Create: `Sources/KleothCore/Summarization/ChatCompleting.swift`
- Modify: `Sources/KleothCore/Summarization/OpenRouterClient.swift` (rename `OpenRouterUsage` → `ChatUsage`, conform, return `ChatCompletion`)
- Modify: `Sources/KleothCore/Summarization/Summarizer.swift:29-36` (`client: any ChatCompleting`)
- Modify: `Sources/KleothCore/Dictation/DictationPolisher.swift:101-131` (`client: any ChatCompleting`)
- Create: `Tests/KleothCoreTests/MockChatClient.swift`
- Test: `Tests/KleothCoreTests/ChatCompletingTests.swift`

**Interfaces:**
- Produces: `protocol ChatCompleting: Sendable { func complete(messages: [ChatMessage], model: String, responseFormat: OpenRouterResponseFormat, maxTokens: Int, temperature: Double?, reasoning: OpenRouterReasoning?) async throws -> ChatCompletion }`, `struct ChatCompletion { content, usage: ChatUsage?, finishReason }`, `struct ChatUsage` (= the old `OpenRouterUsage`; a typealias keeps the old name compiling), `ChatMessage.flattenForSingleTurn(_:) -> (system: String?, prompt: String)`, test helper `MockChatClient`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/KleothCoreTests/ChatCompletingTests.swift
import Testing
import Foundation
@testable import KleothCore

@Suite struct ChatCompletingTests {
    @Test func flattenSplitsSystemFromASingleUserTurn() {
        let messages = [
            ChatMessage(role: "system", content: "Be brief."),
            ChatMessage(role: "user", content: "Hello"),
        ]
        let flat = ChatMessage.flattenForSingleTurn(messages)
        #expect(flat.system == "Be brief.")
        #expect(flat.prompt == "Hello")
    }

    @Test func flattenLabelsMultipleTurns() {
        let messages = [
            ChatMessage(role: "system", content: "S"),
            ChatMessage(role: "user", content: "U1"),
            ChatMessage(role: "assistant", content: "A1"),
            ChatMessage(role: "user", content: "U2"),
        ]
        let flat = ChatMessage.flattenForSingleTurn(messages)
        #expect(flat.system == "S")
        #expect(flat.prompt == "User:\nU1\n\nAssistant:\nA1\n\nUser:\nU2")
    }

    @Test func flattenWithoutSystemHasNilSystem() {
        let flat = ChatMessage.flattenForSingleTurn([ChatMessage(role: "user", content: "x")])
        #expect(flat.system == nil)
        #expect(flat.prompt == "x")
    }

    @Test func summarizerAcceptsAnyChatCompleting() async throws {
        let mock = MockChatClient(results: [.success(ChatCompletion(
            content: #"{"tldr":"t","overview":"o","action_items":[],"per_speaker_highlights":[]}"#,
            usage: nil, finishReason: "stop"))])
        let summarizer = Summarizer(client: mock, model: "any")
        let transcript = Transcript(
            utterances: [Utterance(speakerId: "speaker_0", speakerName: "A", start: 0, end: 1, text: "hi")],
            languageCode: "en", durationSecs: 1)
        let (summary, cost) = try await summarizer.summarize(
            transcript: transcript, metadata: MeetingMetadata(title: "T", date: "2026-09-16"))
        #expect(summary.tldr == "t")
        #expect(cost == 0)
        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].model == "any")
        #expect(mock.calls[0].temperature == nil)
    }
}
```

```swift
// Tests/KleothCoreTests/MockChatClient.swift
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
        lock.lock()
        defer { lock.unlock() }
        calls.append(Call(messages: messages, model: model, responseFormat: responseFormat,
                          maxTokens: maxTokens, temperature: temperature, reasoning: reasoning))
        let result = results[min(index, results.count - 1)]
        if index < results.count - 1 { index += 1 }
        return try result.get()
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ChatCompletingTests`
Expected: compile error — `ChatCompleting`, `ChatCompletion`, `flattenForSingleTurn` do not exist.

- [ ] **Step 3: Add the seam**

```swift
// Sources/KleothCore/Summarization/ChatCompleting.swift
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
```

In `OpenRouterClient.swift`:
- Delete the `OpenRouterUsage` struct (lines 18-31); `ChatUsage` + the typealias replace it. `ResponseBody.usage` stays typed `OpenRouterUsage?` (the typealias).
- Change the struct declaration to `public struct OpenRouterClient: ChatCompleting {`.
- Change `complete(...)`'s return type to `ChatCompletion` and drop the `= nil` defaults on `temperature` / `reasoning` (the protocol extension provides the short form). Keep the body; both `return try await send(...)` lines already return what `send` returns.
- Change `send(...)`'s return type to `ChatCompletion` and its last line to `return ChatCompletion(content: choice.message?.content ?? "", usage: decoded.usage, finishReason: choice.finishReason)`.

In `Summarizer.swift`: `public let client: any ChatCompleting` and `public init(client: any ChatCompleting, model: String = ModelCatalog.defaultModel)`. Update the doc comment above the struct ("using an `OpenRouterClient`" → "using any ``ChatCompleting`` backend").

In `DictationPolisher.swift`: `public let client: any ChatCompleting`, `public init(client: any ChatCompleting, ...)`. Update the comment above the struct: `Sendable` because `ChatCompleting` refines `Sendable`.

- [ ] **Step 4: Run the whole suite**

Run: `swift test`
Expected: all green, including `ChatCompletingTests` (4 tests) and every existing OpenRouter/Summarizer/Polisher test unchanged. If `DictationPolisherTests` or `OpenRouterTemperatureTests` fail to compile on `.usage?.cost`, the `usage` member name on `ChatCompletion` is wrong — it must be `usage`.

- [ ] **Step 5: Build the app package (call sites still compile — nothing there changed)**

Run: `swift build --package-path app`
Expected: succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/KleothCore/Summarization/ChatCompleting.swift Sources/KleothCore/Summarization/OpenRouterClient.swift Sources/KleothCore/Summarization/Summarizer.swift Sources/KleothCore/Dictation/DictationPolisher.swift Tests/KleothCoreTests/MockChatClient.swift Tests/KleothCoreTests/ChatCompletingTests.swift
git commit -m "Core: ChatCompleting seam behind Summarizer and DictationPolisher"
```

---

### Task 2: `OpenAICompatibleClient` (Ollama / LM Studio / any URL)

**Files:**
- Create: `Sources/KleothCore/Summarization/OpenAICompatibleClient.swift`
- Modify: `Sources/KleothCore/Summarization/OpenRouterClient.swift` (becomes a thin wrapper)
- Create: `Sources/KleothCore/Providers/ProviderError.swift`
- Test: `Tests/KleothCoreTests/OpenAICompatibleClientTests.swift`

**Interfaces:**
- Consumes: `ChatCompleting`, `ChatCompletion`, `OpenRouterError`, `OpenRouterResponseFormat`, `HTTPTransport`, `MockTransport`.
- Produces: `struct OpenAICompatibleClient: ChatCompleting { init(baseURL: URL, apiKey: String?, transport: HTTPTransport, sendsOpenRouterProviderKey: Bool = false) }`; `OpenRouterClient(apiKey:transport:)` unchanged in signature; `enum ProviderError: Error, LocalizedError, Equatable` with cases `.noProvider`, `.notInstalled(tool: String)`, `.notSignedIn(tool: String)`, `.unreachable(url: URL)`, `.modelMissing(model: String, hint: String)`, `.inputTooLong`, `.unsupported(String)`, `.backend(String)`, `.timedOut`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/KleothCoreTests/OpenAICompatibleClientTests.swift
import Testing
import Foundation
@testable import KleothCore

@Suite struct OpenAICompatibleClientTests {
    static let okEnvelope = #"{ "choices": [ { "message": { "role": "assistant", "content": "hi" }, "finish_reason": "stop" } ], "usage": { "prompt_tokens": 3, "completion_tokens": 1 } }"#

    static func body(of transport: MockTransport, at index: Int = 0) throws -> [String: Any] {
        let data = try #require(transport.recordedRequests[index].httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func localServerGetsNoProviderKeyAndNoAuthorization() async throws {
        let transport = MockTransport(json: Self.okEnvelope)
        let client = OpenAICompatibleClient(
            baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: nil, transport: transport)
        let completion = try await client.complete(
            messages: [ChatMessage(role: "user", content: "x")], model: "llama3",
            responseFormat: .jsonObject, maxTokens: 10)
        #expect(completion.content == "hi")
        #expect(completion.usage?.promptTokens == 3)
        #expect(completion.usage?.cost == nil)
        let request = transport.recordedRequests[0]
        #expect(request.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try Self.body(of: transport)
        #expect(body["provider"] == nil)
        #expect(body["model"] as? String == "llama3")
    }

    @Test func keyBecomesBearerHeader() async throws {
        let transport = MockTransport(json: Self.okEnvelope)
        let client = OpenAICompatibleClient(
            baseURL: URL(string: "http://localhost:1234/v1")!, apiKey: "test-key", transport: transport)
        _ = try await client.complete(messages: [ChatMessage(role: "user", content: "x")], model: "m",
                                      responseFormat: .none, maxTokens: 10)
        #expect(transport.recordedRequests[0].value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }

    @Test func openRouterWrapperStillSendsProviderKeyAndAttribution() async throws {
        let transport = MockTransport(json: Self.okEnvelope)
        let client = OpenRouterClient(apiKey: "test-key", transport: transport)
        _ = try await client.complete(messages: [ChatMessage(role: "user", content: "x")], model: "m",
                                      responseFormat: .none, maxTokens: 10)
        let request = transport.recordedRequests[0]
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "X-Title") == "Kleoth")
        let body = try Self.body(of: transport)
        let provider = try #require(body["provider"] as? [String: Any])
        #expect(provider["require_parameters"] as? Bool == true)
    }

    @Test func ollamaMissingModelBecomesModelMissing() async throws {
        let transport = MockTransport(
            json: #"{"error":{"message":"model \"llama9\" not found, try pulling it first","type":"api_error"}}"#,
            statusCode: 404)
        let client = OpenAICompatibleClient(
            baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: nil, transport: transport)
        await #expect(throws: ProviderError.modelMissing(model: "llama9", hint: "ollama pull llama9")) {
            _ = try await client.complete(messages: [ChatMessage(role: "user", content: "x")], model: "llama9",
                                          responseFormat: .jsonObject, maxTokens: 10)
        }
        // A missing model is not a routing problem: no relaxed retry.
        #expect(transport.callCount == 1)
    }

    @Test func schemaRejectionStillRetriesAsJSONObject() async throws {
        let transport = MockTransport(outcomes: [
            .success(Data(#"{"error":"unsupported response_format"}"#.utf8),
                     MockTransport.httpResponse(url: URL(string: "http://x")!, statusCode: 400)),
            .success(Data(Self.okEnvelope.utf8),
                     MockTransport.httpResponse(url: URL(string: "http://x")!, statusCode: 200)),
        ])
        let client = OpenAICompatibleClient(
            baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: nil, transport: transport)
        let completion = try await client.complete(
            messages: [ChatMessage(role: "user", content: "x")], model: "m",
            responseFormat: .jsonSchema(name: "s", schemaJSON: #"{"type":"object"}"#), maxTokens: 10)
        #expect(completion.content == "hi")
        #expect(transport.callCount == 2)
        let second = try Self.body(of: transport, at: 1)
        let format = try #require(second["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_object")
    }

    @Test func providerErrorMessagesAreReadable() {
        #expect(ProviderError.notSignedIn(tool: "Claude Code").errorDescription
                == "Claude Code is not signed in. Open a terminal, run `claude`, and sign in.")
        #expect(ProviderError.unreachable(url: URL(string: "http://localhost:11434/v1")!).errorDescription
                == "No server at http://localhost:11434 — is Ollama running?")
        #expect(ProviderError.noProvider.errorDescription
                == "No AI provider available — open Settings → Accounts.")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter OpenAICompatibleClientTests`
Expected: compile error — `OpenAICompatibleClient` / `ProviderError` do not exist.

- [ ] **Step 3: Write `ProviderError`**

```swift
// Sources/KleothCore/Providers/ProviderError.swift
import Foundation

/// Every way a language-model backend can be unusable, with the exact copy
/// the app shows (design doc §6). `Equatable` so tests can match a case.
public enum ProviderError: Error, Equatable, Sendable {
    /// Nothing is configured or installed that can do the task.
    case noProvider
    case notInstalled(tool: String)
    case notSignedIn(tool: String)
    case unreachable(url: URL)
    /// `hint` is the command that fixes it (e.g. `ollama pull llama3`).
    case modelMissing(model: String, hint: String)
    /// The input exceeds the backend's context (Apple on-device: 4096 tokens).
    case inputTooLong
    /// The backend cannot do what was asked (e.g. Apple asked for a summary).
    case unsupported(String)
    /// The backend answered with an error of its own; `message` is verbatim.
    case backend(String)
    case timedOut
}

extension ProviderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noProvider:
            return "No AI provider available — open Settings → Accounts."
        case let .notInstalled(tool):
            return "\(tool) is not installed."
        case let .notSignedIn(tool):
            let command = tool == "Codex" ? "codex login" : "claude"
            return "\(tool) is not signed in. Open a terminal, run `\(command)`, and sign in."
        case let .unreachable(url):
            var origin = url.scheme.map { "\($0)://" } ?? ""
            origin += url.host ?? ""
            if let port = url.port { origin += ":\(port)" }
            return "No server at \(origin) — is Ollama running?"
        case let .modelMissing(model, hint):
            return "Model '\(model)' is not on the local server — run `\(hint)`."
        case .inputTooLong:
            return "Too long for the on-device model."
        case let .unsupported(what):
            return what
        case let .backend(message):
            return message
        case .timedOut:
            return "The AI provider did not answer in time."
        }
    }
}
```

- [ ] **Step 4: Write `OpenAICompatibleClient` and shrink `OpenRouterClient`**

Move the whole body of `OpenRouterClient` (the `ResponseBody`, `complete`, `hasRoutingNarrowingParameters`, `send`, `makeBody`, `snippet`) into the new file as `OpenAICompatibleClient`, with these differences:

```swift
// Sources/KleothCore/Summarization/OpenAICompatibleClient.swift  (header + changed parts)
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Chat-completions client for any server that speaks the OpenAI shape:
/// OpenRouter, Ollama (`http://localhost:11434/v1`), LM Studio
/// (`http://localhost:1234/v1`), vLLM, a corporate gateway.
///
/// Errors are still `OpenRouterError` (the HTTP failure type every caller
/// pattern-matches), except a local server's "model not found" 404, which is
/// rewritten to `ProviderError.modelMissing` so the user gets the pull command
/// instead of a retry.
public struct OpenAICompatibleClient: ChatCompleting {
    /// The API root, e.g. `http://localhost:11434/v1`. `chat/completions` is appended.
    public let baseURL: URL
    /// Bearer token; nil sends no `Authorization` header (Ollama needs none).
    public let apiKey: String?
    public let transport: HTTPTransport
    /// OpenRouter-only: `provider.require_parameters: true` in the body.
    /// Ollama and LM Studio reject unknown top-level keys, so it is off by default.
    public let sendsOpenRouterProviderKey: Bool

    public init(baseURL: URL, apiKey: String?, transport: HTTPTransport, sendsOpenRouterProviderKey: Bool = false) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.transport = transport
        self.sendsOpenRouterProviderKey = sendsOpenRouterProviderKey
    }

    var endpoint: URL {
        baseURL.appendingPathComponent("chat/completions")
    }
    // … ResponseBody, complete(...) and hasRoutingNarrowingParameters(...) verbatim from OpenRouterClient …
```

In `send(...)`:
```swift
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if sendsOpenRouterProviderKey {
            // Optional attribution headers (no secrets) — OpenRouter only.
            request.setValue("https://kleoth.dev", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Kleoth", forHTTPHeaderField: "X-Title")
        }
        request.httpBody = try Self.makeBody(messages: messages, model: model, responseFormat: responseFormat,
                                             maxTokens: maxTokens, temperature: temperature, reasoning: reasoning,
                                             providerKey: sendsOpenRouterProviderKey)

        let (data, response) = try await transport.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(statusCode) else {
            if statusCode == 404, let hint = Self.pullHint(model: model, body: data) {
                throw ProviderError.modelMissing(model: model, hint: hint)
            }
            throw OpenRouterError.httpError(status: statusCode, bodySnippet: Self.snippet(data))
        }
        // … decode as before, return ChatCompletion(...) …
```

`makeBody` gains `providerKey: Bool` and writes `"provider": ["require_parameters": true]` only when it is true.

Add:
```swift
    /// Ollama's 404 for an unpulled model reads `model "x" not found, try
    /// pulling it first`. Recognized by both phrases so a different server's
    /// 404 (bad path) stays an `OpenRouterError`.
    static func pullHint(model: String, body: Data) -> String? {
        let text = String(decoding: body, as: UTF8.self).lowercased()
        guard text.contains("not found"), text.contains("pull") else { return nil }
        return "ollama pull \(model)"
    }
```

Then `OpenRouterClient.swift` keeps `ChatMessage`, `OpenRouterError`, `OpenRouterResponseFormat`, `OpenRouterReasoning` and becomes:

```swift
/// OpenRouter = the OpenAI-compatible client pointed at openrouter.ai with the
/// `provider.require_parameters` routing key and attribution headers.
public struct OpenRouterClient: ChatCompleting {
    public let apiKey: String
    public let transport: HTTPTransport
    private let inner: OpenAICompatibleClient

    public static let baseURL = URL(string: "https://openrouter.ai/api/v1")!

    public init(apiKey: String, transport: HTTPTransport) {
        self.apiKey = apiKey
        self.transport = transport
        self.inner = OpenAICompatibleClient(baseURL: Self.baseURL, apiKey: apiKey, transport: transport,
                                            sendsOpenRouterProviderKey: true)
    }

    public func complete(
        messages: [ChatMessage], model: String, responseFormat: OpenRouterResponseFormat,
        maxTokens: Int, temperature: Double?, reasoning: OpenRouterReasoning?
    ) async throws -> ChatCompletion {
        try await inner.complete(messages: messages, model: model, responseFormat: responseFormat,
                                 maxTokens: maxTokens, temperature: temperature, reasoning: reasoning)
    }
}
```
Keep the long doc comment about the fallback retry on `OpenAICompatibleClient.complete` (it moved with the code).

- [ ] **Step 5: Run the suite**

Run: `swift test`
Expected: green. `OpenRouterTemperatureTests` (body byte-identity) and `ModelCatalogTests` must still pass — they prove the OpenRouter body did not change.

- [ ] **Step 6: Commit**

```bash
git add Sources/KleothCore/Summarization/OpenAICompatibleClient.swift Sources/KleothCore/Summarization/OpenRouterClient.swift Sources/KleothCore/Providers/ProviderError.swift Tests/KleothCoreTests/OpenAICompatibleClientTests.swift
git commit -m "Core: OpenAICompatibleClient for local servers; OpenRouterClient wraps it"
```

---

### Task 3: `AIProvider` and `ProviderSettings`

**Files:**
- Create: `Sources/KleothCore/Providers/AIProvider.swift`
- Create: `Sources/KleothCore/Providers/ProviderSettings.swift`
- Modify: `Sources/KleothCore/Config/Settings.swift` (add `providerSettings`)
- Test: `Tests/KleothCoreTests/AIProviderTests.swift`, `Tests/KleothCoreTests/ProviderSettingsTests.swift`

**Interfaces:**
- Produces: `enum AIProvider: String, Codable, CaseIterable, Sendable, Identifiable` (`openRouter="openrouter"`, `localServer="local"`, `claudeCode="claude-code"`, `codex="codex"`, `appleOnDevice="apple"`), `AIProvider.Task` (`summary`, `dictation`), `AIProvider.autoOrder`, `supports(_:)`, `displayName`, `defaultModel(for:)`, `modelChoice`, `AIProvider.parse(_:)`; `struct ProviderSettings { pick, localServerURL, localServerKey, models; static load(config:); model(for:on:); settingModel(_:for:on:); modelsJSON; static defaultLocalServerURL }`; `Settings.providerSettings`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/KleothCoreTests/AIProviderTests.swift
import Testing
@testable import KleothCore

@Suite struct AIProviderTests {
    @Test func rawValuesAreTheStoredIds() {
        #expect(AIProvider.claudeCode.rawValue == "claude-code")
        #expect(AIProvider.appleOnDevice.rawValue == "apple")
        #expect(AIProvider.localServer.rawValue == "local")
    }

    @Test func taskSupport() {
        #expect(AIProvider.codex.supports(.summary))
        #expect(!AIProvider.codex.supports(.dictation))
        #expect(AIProvider.appleOnDevice.supports(.dictation))
        #expect(!AIProvider.appleOnDevice.supports(.summary))
        for provider in [AIProvider.openRouter, .localServer, .claudeCode] {
            #expect(provider.supports(.summary) && provider.supports(.dictation))
        }
    }

    @Test func autoOrderIsTheSpecOrder() {
        #expect(AIProvider.autoOrder == [.localServer, .claudeCode, .codex, .openRouter, .appleOnDevice])
    }

    @Test func defaultModels() {
        #expect(AIProvider.openRouter.defaultModel(for: .summary) == ModelCatalog.defaultModel)
        #expect(AIProvider.openRouter.defaultModel(for: .dictation) == DictationDefaults.polishModel)
        #expect(AIProvider.claudeCode.defaultModel(for: .summary) == "sonnet")
        #expect(AIProvider.claudeCode.defaultModel(for: .dictation) == "haiku")
        #expect(AIProvider.codex.defaultModel(for: .summary) == "")
        #expect(AIProvider.localServer.defaultModel(for: .summary) == "")
        #expect(AIProvider.appleOnDevice.defaultModel(for: .dictation) == "apple-on-device")
    }

    @Test func parseAcceptsIdsAndTreatsAutoAsNil() {
        #expect(AIProvider.parse("claude-code") == .claudeCode)
        #expect(AIProvider.parse("auto") == nil)
        #expect(AIProvider.parse("") == nil)
        #expect(AIProvider.parse(nil) == nil)
        #expect(AIProvider.parse("bogus") == nil)
    }
}
```

```swift
// Tests/KleothCoreTests/ProviderSettingsTests.swift
import Testing
import Foundation
@testable import KleothCore

@Suite struct ProviderSettingsTests {
    @Test func defaultsWhenNothingIsConfigured() {
        let settings = ProviderSettings.load(config: [:])
        #expect(settings.pick == nil)
        #expect(settings.localServerURL == ProviderSettings.defaultLocalServerURL)
        #expect(settings.localServerKey == nil)
        #expect(settings.models.isEmpty)
        #expect(settings.model(for: .summary, on: .claudeCode) == "sonnet")
    }

    @Test func parsesEveryKey() {
        let settings = ProviderSettings.load(config: [
            "ai_provider": "codex",
            "local_server_url": "http://localhost:1234/v1",
            "local_server_key": "test-key",
            "ai_models": #"{"claude-code":{"summary":"opus"},"local":{"dictation":"qwen3"}}"#,
        ])
        #expect(settings.pick == .codex)
        #expect(settings.localServerURL.absoluteString == "http://localhost:1234/v1")
        #expect(settings.localServerKey == "test-key")
        #expect(settings.model(for: .summary, on: .claudeCode) == "opus")
        #expect(settings.model(for: .dictation, on: .claudeCode) == "haiku")
        #expect(settings.model(for: .dictation, on: .localServer) == "qwen3")
    }

    @Test func badValuesFallBack() {
        let settings = ProviderSettings.load(config: [
            "ai_provider": "nope",
            "local_server_url": "not a url at all",
            "ai_models": "{{{",
        ])
        #expect(settings.pick == nil)
        #expect(settings.localServerURL == ProviderSettings.defaultLocalServerURL)
        #expect(settings.models.isEmpty)
    }

    @Test func urlWithoutSchemeGetsHTTPAndTrailingSlashIsDropped() {
        let settings = ProviderSettings.load(config: ["local_server_url": "localhost:11434/v1/"])
        #expect(settings.localServerURL.absoluteString == "http://localhost:11434/v1")
    }

    @Test func settingModelRoundTripsThroughJSON() throws {
        var settings = ProviderSettings.load(config: [:])
        settings = settings.settingModel("opus", for: .summary, on: .claudeCode)
        settings = settings.settingModel("llama3", for: .dictation, on: .localServer)
        let reloaded = ProviderSettings.load(config: ["ai_models": settings.modelsJSON])
        #expect(reloaded.models == settings.models)
        #expect(reloaded.model(for: .summary, on: .claudeCode) == "opus")
        // Unknown providers/tasks in a stored blob are ignored, not fatal.
        let lenient = ProviderSettings.parseModels(#"{"gemini":{"summary":"x"},"codex":{"poem":"y","summary":"o3"}}"#)
        #expect(lenient == [.codex: [.summary: "o3"]])
    }

    @Test func settingsLoadCarriesProviderSettings() {
        let settings = Settings.load(config: ["ai_provider": "local"])
        #expect(settings.providerSettings.pick == .localServer)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter "AIProviderTests|ProviderSettingsTests"`
Expected: compile errors on the missing types.

- [ ] **Step 3: Write `AIProvider`**

```swift
// Sources/KleothCore/Providers/AIProvider.swift
import Foundation

/// A language-model backend Kleoth can run summaries and dictation polish on.
/// The raw value is the stored id (`ai_provider`, `summary_provider`,
/// `polish_provider`, the `ai_models` keys, `--provider`).
public enum AIProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case openRouter = "openrouter"
    case localServer = "local"
    case claudeCode = "claude-code"
    case codex = "codex"
    case appleOnDevice = "apple"

    /// The two things a provider is asked to do.
    public enum Task: String, Sendable, CaseIterable, Codable {
        case summary, dictation
    }

    /// How Settings lets the user choose a model on this provider.
    public enum ModelChoice: Sendable, Equatable {
        /// OpenRouter's live catalog (`ModelCatalog`).
        case openRouterCatalog
        /// `GET <base>/models` on the local server.
        case serverList
        /// A fixed list of aliases.
        case aliases([String])
        /// Free text; empty means the account default.
        case freeText(placeholder: String)
        /// One model, nothing to pick.
        case fixed
    }

    public var id: String { rawValue }

    /// The order Automatic tries, per task, skipping providers that cannot do
    /// the task or are unavailable.
    public static let autoOrder: [AIProvider] = [.localServer, .claudeCode, .codex, .openRouter, .appleOnDevice]

    /// Claude Code's model aliases (`claude --model`).
    public static let claudeCodeAliases = ["haiku", "sonnet", "opus", "fable"]

    public func supports(_ task: Task) -> Bool {
        switch (self, task) {
        case (.codex, .dictation): return false      // 12 s per call — summaries only
        case (.appleOnDevice, .summary): return false // 4096-token context
        default: return true
        }
    }

    public var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .localServer: return "Local server"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .appleOnDevice: return "Apple on-device"
        }
    }

    /// The model used when the user has not picked one for `task`.
    /// Empty = "the backend's own default" (local server: the first model it
    /// lists; Codex: the account default, no `-m`).
    public func defaultModel(for task: Task) -> String {
        switch (self, task) {
        case (.openRouter, .summary): return ModelCatalog.defaultModel
        case (.openRouter, .dictation): return DictationDefaults.polishModel
        case (.claudeCode, .summary): return "sonnet"
        case (.claudeCode, .dictation): return "haiku"
        case (.appleOnDevice, _): return "apple-on-device"
        case (.localServer, _), (.codex, _): return ""
        }
    }

    public var modelChoice: ModelChoice {
        switch self {
        case .openRouter: return .openRouterCatalog
        case .localServer: return .serverList
        case .claudeCode: return .aliases(Self.claudeCodeAliases)
        case .codex: return .freeText(placeholder: "Account default")
        case .appleOnDevice: return .fixed
        }
    }

    /// A stored / typed id → provider. `nil`, empty, `"auto"` and unknown
    /// strings all mean Automatic.
    public static func parse(_ raw: String?) -> AIProvider? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty, raw != "auto" else { return nil }
        return AIProvider(rawValue: raw)
    }
}
```

- [ ] **Step 4: Write `ProviderSettings` and wire `Settings.providerSettings`**

```swift
// Sources/KleothCore/Providers/ProviderSettings.swift
import Foundation

/// The user's provider choices, parsed from the flat string config
/// (`config.json` for the CLI, the Keychain overlay in the app). Pure and
/// value-typed so both can share the parsing and the tests.
public struct ProviderSettings: Sendable, Equatable {
    /// Explicit pick; nil = Automatic.
    public var pick: AIProvider?
    /// API root of the local OpenAI-compatible server.
    public var localServerURL: URL
    /// Optional bearer token for the local server (LM Studio can require one).
    public var localServerKey: String?
    /// Per-provider, per-task model overrides. Absent → `provider.defaultModel(for:)`.
    public var models: [AIProvider: [AIProvider.Task: String]]

    public static let defaultLocalServerURL = URL(string: "http://localhost:11434/v1")!

    public init(
        pick: AIProvider? = nil,
        localServerURL: URL = ProviderSettings.defaultLocalServerURL,
        localServerKey: String? = nil,
        models: [AIProvider: [AIProvider.Task: String]] = [:]
    ) {
        self.pick = pick
        self.localServerURL = localServerURL
        self.localServerKey = localServerKey
        self.models = models
    }

    // MARK: - Parsing

    public static func load(config: [String: String]) -> ProviderSettings {
        var settings = ProviderSettings()
        settings.pick = AIProvider.parse(config["ai_provider"])
        settings.localServerURL = normalizeServerURL(config["local_server_url"]) ?? defaultLocalServerURL
        if let key = config["local_server_key"], !key.isEmpty {
            settings.localServerKey = key
        }
        settings.models = parseModels(config["ai_models"])
        return settings
    }

    /// `"localhost:11434/v1/"` → `http://localhost:11434/v1`. nil for empty
    /// or unparseable input (the caller falls back to the default).
    public static func normalizeServerURL(_ raw: String?) -> URL? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let host = url.host, !host.isEmpty, !host.contains(" ") else { return nil }
        return url
    }

    /// Decodes the `ai_models` blob leniently: unknown providers and tasks are
    /// dropped, anything undecodable yields an empty map.
    public static func parseModels(_ json: String?) -> [AIProvider: [AIProvider.Task: String]] {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [AIProvider: [AIProvider.Task: String]] = [:]
        for (providerKey, value) in object {
            guard let provider = AIProvider(rawValue: providerKey),
                  let byTask = value as? [String: Any] else { continue }
            var models: [AIProvider.Task: String] = [:]
            for (taskKey, model) in byTask {
                if let task = AIProvider.Task(rawValue: taskKey), let model = model as? String, !model.isEmpty {
                    models[task] = model
                }
            }
            if !models.isEmpty { result[provider] = models }
        }
        return result
    }

    // MARK: - Models

    /// The model to use for `task` on `provider`: the stored override, else
    /// the provider's default.
    public func model(for task: AIProvider.Task, on provider: AIProvider) -> String {
        models[provider]?[task] ?? provider.defaultModel(for: task)
    }

    /// A copy with one override set (empty `model` removes the override).
    public func settingModel(_ model: String, for task: AIProvider.Task, on provider: AIProvider) -> ProviderSettings {
        var copy = self
        var byTask = copy.models[provider] ?? [:]
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { byTask[task] = nil } else { byTask[task] = trimmed }
        copy.models[provider] = byTask.isEmpty ? nil : byTask
        return copy
    }

    /// The `ai_models` blob to persist. Keys sorted so the value is stable.
    public var modelsJSON: String {
        var object: [String: [String: String]] = [:]
        for (provider, byTask) in models {
            object[provider.rawValue] = Dictionary(uniqueKeysWithValues: byTask.map { ($0.key.rawValue, $0.value) })
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
```

In `Settings.swift`: add `public var providerSettings: ProviderSettings` after `inputDeviceId` with the doc comment "Which language-model backend runs summaries and dictation polish (design doc 2026-09-15)"; add `providerSettings: ProviderSettings = ProviderSettings()` as the last `init` parameter and assign it; in `load(config:)` add `let providerSettings = ProviderSettings.load(config: config)` and pass it.

- [ ] **Step 5: Run the suite**

Run: `swift test`
Expected: green (10 new tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/KleothCore/Providers/AIProvider.swift Sources/KleothCore/Providers/ProviderSettings.swift Sources/KleothCore/Config/Settings.swift Tests/KleothCoreTests/AIProviderTests.swift Tests/KleothCoreTests/ProviderSettingsTests.swift
git commit -m "Core: AIProvider ids, task support, defaults; ProviderSettings parsing"
```

---

### Task 4: `ProviderResolver` (pure)

**Files:**
- Create: `Sources/KleothCore/Providers/ProviderResolver.swift`
- Test: `Tests/KleothCoreTests/ProviderResolverTests.swift`

**Interfaces:**
- Consumes: `AIProvider`, `AIProvider.Task`.
- Produces: `enum ProviderAvailability: Sendable, Equatable { case available(detail: String, models: [String] = []); case unavailable(reason: String) }`, `typealias ProviderSnapshot = [AIProvider: ProviderAvailability]`, `enum ProviderResolver { static func resolve(task:pick:snapshot:) -> Resolution }`, `enum Resolution: Equatable { case provider(AIProvider, fellThroughFrom: AIProvider?); case unavailable(AIProvider, reason: String); case none }`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/KleothCoreTests/ProviderResolverTests.swift
import Testing
@testable import KleothCore

@Suite struct ProviderResolverTests {
    static func snapshot(_ available: Set<AIProvider>) -> ProviderSnapshot {
        var result: ProviderSnapshot = [:]
        for provider in AIProvider.allCases {
            result[provider] = available.contains(provider)
                ? .available(detail: provider.displayName)
                : .unavailable(reason: "Not installed")
        }
        return result
    }

    @Test func automaticWalksTheOrder() {
        let snap = Self.snapshot([.claudeCode, .openRouter])
        #expect(ProviderResolver.resolve(task: .summary, pick: nil, snapshot: snap)
                == .provider(.claudeCode, fellThroughFrom: nil))
        let onlyRouter = Self.snapshot([.openRouter, .appleOnDevice])
        #expect(ProviderResolver.resolve(task: .summary, pick: nil, snapshot: onlyRouter)
                == .provider(.openRouter, fellThroughFrom: nil))
    }

    @Test func automaticSkipsProvidersThatCannotDoTheTask() {
        let snap = Self.snapshot([.codex, .appleOnDevice])
        #expect(ProviderResolver.resolve(task: .dictation, pick: nil, snapshot: snap)
                == .provider(.appleOnDevice, fellThroughFrom: nil))
        #expect(ProviderResolver.resolve(task: .summary, pick: nil, snapshot: snap)
                == .provider(.codex, fellThroughFrom: nil))
    }

    @Test func nothingAvailableIsNone() {
        #expect(ProviderResolver.resolve(task: .summary, pick: nil, snapshot: Self.snapshot([])) == .none)
        #expect(ProviderResolver.resolve(task: .summary, pick: nil, snapshot: [:]) == .none)
    }

    @Test func explicitAvailablePickWins() {
        let snap = Self.snapshot([.localServer, .claudeCode, .openRouter])
        #expect(ProviderResolver.resolve(task: .summary, pick: .openRouter, snapshot: snap)
                == .provider(.openRouter, fellThroughFrom: nil))
    }

    @Test func explicitPickThatCannotDoTheTaskFallsThrough() {
        let snap = Self.snapshot([.appleOnDevice, .claudeCode])
        #expect(ProviderResolver.resolve(task: .summary, pick: .appleOnDevice, snapshot: snap)
                == .provider(.claudeCode, fellThroughFrom: .appleOnDevice))
        #expect(ProviderResolver.resolve(task: .dictation, pick: .appleOnDevice, snapshot: snap)
                == .provider(.appleOnDevice, fellThroughFrom: nil))
    }

    @Test func explicitUnavailablePickIsReportedNotReplaced() {
        let snap = Self.snapshot([.openRouter])
        #expect(ProviderResolver.resolve(task: .summary, pick: .claudeCode, snapshot: snap)
                == .unavailable(.claudeCode, reason: "Not installed"))
    }

    @Test func fallThroughWithNothingElseIsNone() {
        let snap = Self.snapshot([.appleOnDevice])
        #expect(ProviderResolver.resolve(task: .summary, pick: .appleOnDevice, snapshot: snap) == .none)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter ProviderResolverTests`
Expected: compile errors.

- [ ] **Step 3: Write the resolver**

```swift
// Sources/KleothCore/Providers/ProviderResolver.swift
import Foundation

/// What the detector found for one provider. `detail` / `reason` are the
/// strings Settings shows under the provider's name.
public enum ProviderAvailability: Sendable, Equatable {
    /// `models` is filled only for the local server (its `/v1/models` ids),
    /// so an empty model pick can default to the first one it serves.
    case available(detail: String, models: [String] = [])
    case unavailable(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

public typealias ProviderSnapshot = [AIProvider: ProviderAvailability]

/// Picks the provider for one task from the user's choice and a snapshot.
/// Pure — `ProviderDetector` produces the snapshot, the factory acts on the
/// resolution.
public enum ProviderResolver {
    public enum Resolution: Sendable, Equatable {
        /// Use this provider. `fellThroughFrom` names an explicit pick that
        /// cannot do the task (Apple on-device asked for a summary) — Settings
        /// says so in its footer.
        case provider(AIProvider, fellThroughFrom: AIProvider?)
        /// The user picked a provider that can do the task but is not usable
        /// right now (not installed, not signed in, server down). Surfaced as
        /// an error, never silently replaced.
        case unavailable(AIProvider, reason: String)
        /// Nothing can do the task.
        case none
    }

    public static func resolve(task: AIProvider.Task, pick: AIProvider?, snapshot: ProviderSnapshot) -> Resolution {
        if let pick {
            if pick.supports(task) {
                switch snapshot[pick] {
                case .available:
                    return .provider(pick, fellThroughFrom: nil)
                case let .unavailable(reason):
                    return .unavailable(pick, reason: reason)
                case nil:
                    return .unavailable(pick, reason: "Not detected")
                }
            }
            if let next = firstAvailable(task: task, snapshot: snapshot, excluding: pick) {
                return .provider(next, fellThroughFrom: pick)
            }
            return .none
        }
        if let first = firstAvailable(task: task, snapshot: snapshot, excluding: nil) {
            return .provider(first, fellThroughFrom: nil)
        }
        return .none
    }

    private static func firstAvailable(task: AIProvider.Task, snapshot: ProviderSnapshot, excluding: AIProvider?) -> AIProvider? {
        AIProvider.autoOrder.first { provider in
            provider != excluding && provider.supports(task) && (snapshot[provider]?.isAvailable ?? false)
        }
    }
}
```

- [ ] **Step 4: Run the suite**

Run: `swift test --filter ProviderResolverTests`
Expected: 7 green.

- [ ] **Step 5: Commit**

```bash
git add Sources/KleothCore/Providers/ProviderResolver.swift Tests/KleothCoreTests/ProviderResolverTests.swift
git commit -m "Core: ProviderResolver — explicit pick, task fall-through, auto order"
```

---

### Task 5: `ProcessRunner` and `ToolLocator`

**Files:**
- Create: `Sources/KleothCore/Providers/ProcessRunner.swift`
- Create: `Sources/KleothCore/Providers/ToolLocator.swift`
- Create: `Tests/KleothCoreTests/MockProcessRunner.swift`
- Test: `Tests/KleothCoreTests/ProcessRunnerTests.swift`, `Tests/KleothCoreTests/ToolLocatorTests.swift`

**Interfaces:**
- Produces: `struct ProcessResult: Sendable, Equatable { stdout: Data; stderr: Data; status: Int32; var stdoutText: String; var stderrText: String }`, `protocol ProcessRunner: Sendable { func run(executable: URL, arguments: [String], stdin: Data?, environment: [String: String], timeout: TimeInterval) async throws -> ProcessResult }`, `struct FoundationProcessRunner: ProcessRunner`, `struct ToolLocator: Sendable { init(searchDirectories: [URL]); static let standard; func find(_ name: String) -> URL?; var pathValue: String; func environment() -> [String: String] }`, test helper `MockProcessRunner`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/KleothCoreTests/MockProcessRunner.swift
import Foundation
@testable import KleothCore

/// Records every spawn and answers with canned results in order (last repeats).
final class MockProcessRunner: ProcessRunner, @unchecked Sendable {
    struct Call: Sendable {
        let executable: URL
        let arguments: [String]
        let stdin: Data?
        let environment: [String: String]
        let timeout: TimeInterval
        var stdinText: String? { stdin.map { String(decoding: $0, as: UTF8.self) } }
    }

    private let lock = NSLock()
    private let results: [Result<ProcessResult, Error>]
    private var index = 0
    private(set) var calls: [Call] = []

    init(results: [Result<ProcessResult, Error>]) {
        self.results = results
    }

    convenience init(stdout: String, status: Int32 = 0) {
        self.init(results: [.success(ProcessResult(stdout: Data(stdout.utf8), stderr: Data(), status: status))])
    }

    func run(executable: URL, arguments: [String], stdin: Data?, environment: [String: String], timeout: TimeInterval) async throws -> ProcessResult {
        lock.lock()
        defer { lock.unlock() }
        calls.append(Call(executable: executable, arguments: arguments, stdin: stdin, environment: environment, timeout: timeout))
        let result = results[min(index, results.count - 1)]
        if index < results.count - 1 { index += 1 }
        return try result.get()
    }
}
```

```swift
// Tests/KleothCoreTests/ProcessRunnerTests.swift
import Testing
import Foundation
@testable import KleothCore

@Suite struct ProcessRunnerTests {
    let runner = FoundationProcessRunner()

    @Test func capturesStdoutAndStatus() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["hello"],
            stdin: nil, environment: [:], timeout: 5)
        #expect(result.stdoutText == "hello\n")
        #expect(result.status == 0)
    }

    @Test func feedsStdinAndCapturesStderr() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "cat; echo oops 1>&2; exit 3"],
            stdin: Data("payload".utf8), environment: [:], timeout: 5)
        #expect(result.stdoutText == "payload")
        #expect(result.stderrText == "oops\n")
        #expect(result.status == 3)
    }

    @Test func timeoutTerminatesTheProcess() async throws {
        let started = Date()
        await #expect(throws: ProviderError.timedOut) {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                stdin: nil, environment: [:], timeout: 0.3)
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func cancellationTerminatesTheProcess() async throws {
        let started = Date()
        let task = Task {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                stdin: nil, environment: [:], timeout: 60)
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func missingExecutableThrows() async {
        await #expect(throws: (any Error).self) {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/nonexistent/tool"), arguments: [],
                stdin: nil, environment: [:], timeout: 5)
        }
    }
}
```

```swift
// Tests/KleothCoreTests/ToolLocatorTests.swift
import Testing
import Foundation
@testable import KleothCore

@Suite struct ToolLocatorTests {
    /// A temp tree: `a/` (empty), `b/claude` (executable), `c/claude` (executable).
    static func makeTree() throws -> (root: URL, dirs: [URL]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-locator-\(UUID().uuidString)", isDirectory: true)
        var dirs: [URL] = []
        for name in ["a", "b", "c"] {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            dirs.append(dir)
        }
        for dir in dirs.dropFirst() {
            let file = dir.appendingPathComponent("claude")
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        // A non-executable file must not count.
        let plain = dirs[0].appendingPathComponent("codex")
        try Data("x".utf8).write(to: plain)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path)
        return (root, dirs)
    }

    @Test func firstExecutableInSearchOrderWins() throws {
        let (root, dirs) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = ToolLocator(searchDirectories: dirs)
        #expect(locator.find("claude") == dirs[1].appendingPathComponent("claude"))
        #expect(locator.find("codex") == nil)
        #expect(locator.find("nothing") == nil)
    }

    @Test func pathValueJoinsDirectories() {
        let locator = ToolLocator(searchDirectories: [URL(fileURLWithPath: "/x/bin"), URL(fileURLWithPath: "/y")])
        #expect(locator.pathValue == "/x/bin:/y")
        let env = locator.environment()
        #expect(env["PATH"] == "/x/bin:/y")
        #expect(env["HOME"] == FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(env["LANG"] == "en_US.UTF-8")
    }

    @Test func standardLocatorSearchesTheUsualPlacesFirst() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs = ToolLocator.standard.searchDirectories.map(\.path)
        #expect(dirs.prefix(3) == [
            home.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ])
        #expect(dirs.contains(home.appendingPathComponent(".local/share/mise/shims").path))
        #expect(dirs.contains(home.appendingPathComponent(".codex/bin").path))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter "ProcessRunnerTests|ToolLocatorTests"`
Expected: compile errors.

- [ ] **Step 3: Write `ProcessRunner`**

```swift
// Sources/KleothCore/Providers/ProcessRunner.swift
import Foundation

/// What a finished child process left behind.
public struct ProcessResult: Sendable, Equatable {
    public let stdout: Data
    public let stderr: Data
    public let status: Int32

    public init(stdout: Data, stderr: Data, status: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// The seam the CLI adapters spawn through. `FoundationProcessRunner` in the
/// app and probes; a recording mock in tests.
public protocol ProcessRunner: Sendable {
    /// Runs `executable` to completion. `stdin` is written then closed.
    /// Throws `ProviderError.timedOut` after `timeout` seconds (the process
    /// is terminated), and `CancellationError` when the calling task is
    /// cancelled (likewise terminated). A non-zero exit is NOT an error here —
    /// the adapter decides what the output means.
    func run(
        executable: URL,
        arguments: [String],
        stdin: Data?,
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> ProcessResult
}

/// `Foundation.Process` behind ``ProcessRunner``. Both pipes are drained on
/// background tasks from the moment the process starts (a full pipe would
/// otherwise block the child forever), and termination is awaited through the
/// process's own `terminationHandler`.
public struct FoundationProcessRunner: ProcessRunner {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        stdin: Data?,
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        let box = ProcessBox(executable: executable, arguments: arguments, environment: environment)
        try box.start(stdin: stdin)

        let status: Int32 = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask { await box.waitForExit() }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    box.terminate()
                    throw ProviderError.timedOut
                }
                // The first child to finish decides: exit status, or the
                // timeout's thrown error (which also terminated the process).
                guard let first = try await group.next() else { throw ProviderError.timedOut }
                group.cancelAll()
                return first
            }
        } onCancel: {
            box.terminate()
        }
        try Task.checkCancellation()
        return ProcessResult(stdout: await box.stdout(), stderr: await box.stderr(), status: status)
    }
}

/// Owns the `Process` and its pipes. `@unchecked Sendable`: every mutation
/// happens on `start` (before any concurrent access) or through Foundation's
/// own thread-safe `Process` API (`terminate`, `terminationHandler`).
private final class ProcessBox: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinPipe = Pipe()
    private var stdoutTask: Task<Data, Never>?
    private var stderrTask: Task<Data, Never>?

    init(executable: URL, arguments: [String], environment: [String: String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe
    }

    func start(stdin: Data?) throws {
        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading
        stdoutTask = Task.detached { outHandle.readDataToEndOfFile() }
        stderrTask = Task.detached { errHandle.readDataToEndOfFile() }
        try process.run()
        let inHandle = stdinPipe.fileHandleForWriting
        if let stdin, !stdin.isEmpty {
            try? inHandle.write(contentsOf: stdin)
        }
        try? inHandle.close()
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            if !process.isRunning {
                continuation.resume(returning: process.terminationStatus)
                return
            }
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            // The handler is installed after `run()`; if the process exited in
            // between, the handler never fires — re-check.
            if !process.isRunning {
                process.terminationHandler = nil
                continuation.resume(returning: process.terminationStatus)
            }
        }
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        // SIGTERM is polite; a stuck child gets SIGKILL two seconds later.
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    func stdout() async -> Data { await stdoutTask?.value ?? Data() }
    func stderr() async -> Data { await stderrTask?.value ?? Data() }
}
```

If the compiler rejects `FileHandle` capture in `Task.detached` under strict concurrency, wrap the two handles: `nonisolated(unsafe) let outHandle = stdoutPipe.fileHandleForReading` — `FileHandle` is thread-safe for a single reader and nothing else touches it.

The `waitForExit` double-resume risk: `terminationHandler` and the post-check can both fire if the process exits between the `isRunning` check and the handler assignment. Guard with a flag inside the box:
```swift
    private let exitLock = NSLock()
    private var resumed = false
    private func resumeOnce(_ continuation: CheckedContinuation<Int32, Never>, _ status: Int32) {
        exitLock.lock(); defer { exitLock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: status)
    }
```
and call `resumeOnce` from both places instead of `continuation.resume`.

- [ ] **Step 4: Write `ToolLocator`**

```swift
// Sources/KleothCore/Providers/ToolLocator.swift
import Foundation

/// Finds installed CLIs. A GUI app's `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin`,
/// so the usual install locations are searched explicitly, before `$PATH`.
public struct ToolLocator: Sendable {
    public let searchDirectories: [URL]

    public init(searchDirectories: [URL]) {
        self.searchDirectories = searchDirectories
    }

    /// `~/.local/bin` (Claude Code's installer), Homebrew, `/usr/local/bin`,
    /// mise shims, `~/.codex/bin`, then every `$PATH` entry not already listed.
    public static let standard: ToolLocator = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs: [URL] = [
            home.appendingPathComponent(".local/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            home.appendingPathComponent(".local/share/mise/shims", isDirectory: true),
            home.appendingPathComponent(".codex/bin", isDirectory: true),
        ]
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for entry in path.split(separator: ":") where !entry.isEmpty {
            let url = URL(fileURLWithPath: String(entry), isDirectory: true)
            if !dirs.contains(where: { $0.path == url.path }) { dirs.append(url) }
        }
        return ToolLocator(searchDirectories: dirs)
    }()

    /// The first executable regular file named `name` in search order.
    public func find(_ name: String) -> URL? {
        let fm = FileManager.default
        for dir in searchDirectories {
            let candidate = dir.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  fm.isExecutableFile(atPath: candidate.path) else { continue }
            return candidate
        }
        return nil
    }

    /// `PATH` for a spawned tool.
    public var pathValue: String {
        searchDirectories.map(\.path).joined(separator: ":")
    }

    /// The minimal environment a spawned tool gets: enough to find its own
    /// config, keychain and temp dir — nothing inherited from Kleoth beyond that.
    public func environment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": pathValue,
            "LANG": "en_US.UTF-8",
            "TMPDIR": inherited["TMPDIR"] ?? NSTemporaryDirectory(),
        ]
        if let user = inherited["USER"] { env["USER"] = user }
        return env
    }
}
```

- [ ] **Step 5: Run the suite**

Run: `swift test --filter "ProcessRunnerTests|ToolLocatorTests"`
Expected: 8 green. If `timeoutTerminatesTheProcess` hangs, `waitForExit` never resumed — check the `resumeOnce` guard and that `terminationHandler` is set before `run()` returns control.

- [ ] **Step 6: Commit**

```bash
git add Sources/KleothCore/Providers/ProcessRunner.swift Sources/KleothCore/Providers/ToolLocator.swift Tests/KleothCoreTests/MockProcessRunner.swift Tests/KleothCoreTests/ProcessRunnerTests.swift Tests/KleothCoreTests/ToolLocatorTests.swift
git commit -m "Core: ProcessRunner (Foundation.Process with timeout/cancel) and ToolLocator"
```

---

### Task 6: `ClaudeCodeClient`

**Files:**
- Create: `Sources/KleothCore/Providers/ClaudeCodeClient.swift`
- Test: `Tests/KleothCoreTests/ClaudeCodeClientTests.swift`

**Interfaces:**
- Consumes: `ChatCompleting`, `ChatMessage.flattenForSingleTurn`, `ProcessRunner`, `ProviderError`.
- Produces: `struct ClaudeCodeClient: ChatCompleting { init(executable: URL, runner: any ProcessRunner, environment: [String: String], timeout: TimeInterval = 600); static let toolName = "Claude Code"; static func arguments(model:responseFormat:systemPrompt:) -> [String]; static func prompt(for:responseFormat:) -> String; static func parse(_ stdout: Data) throws -> ChatCompletion }`.

- [ ] **Step 1: Write the failing tests**

The fixtures are the real outputs captured on 2026-09-15 (trimmed to the keys the parser reads).

```swift
// Tests/KleothCoreTests/ClaudeCodeClientTests.swift
import Testing
import Foundation
@testable import KleothCore

@Suite struct ClaudeCodeClientTests {
    static let ok = #"{"duration_api_ms":1500,"stop_reason":"end_turn","session_id":"x","total_cost_usd":0.0027,"usage":{"input_tokens":1111,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":9},"is_error":false,"num_turns":1,"subtype":"success","result":"{\"word\":\"ok\"}","structured_output":{"word":"ok"},"type":"result"}"#
    static let notLoggedIn = #"{"duration_api_ms":0,"stop_reason":"stop_sequence","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0},"is_error":true,"num_turns":1,"subtype":"success","result":"Not logged in · Please run /login","type":"result"}"#
    static let plainText = #"{"stop_reason":"end_turn","is_error":false,"subtype":"success","result":"Hello there","usage":{"input_tokens":5,"output_tokens":2},"type":"result"}"#
    static let truncated = #"{"stop_reason":"max_tokens","is_error":false,"subtype":"success","result":"{\"tldr\":\"cut","usage":{"input_tokens":5,"output_tokens":2},"type":"result"}"#

    static let schema = #"{"type":"object","properties":{"word":{"type":"string"}},"required":["word"]}"#

    func client(_ runner: MockProcessRunner) -> ClaudeCodeClient {
        ClaudeCodeClient(executable: URL(fileURLWithPath: "/fake/claude"), runner: runner,
                         environment: ["HOME": "/Users/test"], timeout: 42)
    }

    @Test func argumentsIsolateTheSessionAndPassSchema() {
        let args = ClaudeCodeClient.arguments(
            model: "haiku", responseFormat: .jsonSchema(name: "w", schemaJSON: Self.schema), systemPrompt: "Be terse.")
        #expect(args == [
            "-p", "--output-format", "json", "--tools", "", "--no-session-persistence",
            "--setting-sources", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
            "--model", "haiku", "--system-prompt", "Be terse.", "--json-schema", Self.schema,
        ])
    }

    @Test func argumentsOmitEmptyModelAndSystem() {
        let args = ClaudeCodeClient.arguments(model: "", responseFormat: .none, systemPrompt: nil)
        #expect(!args.contains("--model"))
        #expect(!args.contains("--system-prompt"))
        #expect(!args.contains("--json-schema"))
    }

    @Test func jsonObjectFormatAppendsAnInstructionToThePrompt() {
        let prompt = ClaudeCodeClient.prompt(for: "Summarize.", responseFormat: .jsonObject)
        #expect(prompt == "Summarize.\n\nReturn only a JSON object, no prose.")
        #expect(ClaudeCodeClient.prompt(for: "Hi", responseFormat: .none) == "Hi")
    }

    @Test func structuredOutputIsReserializedAsContent() throws {
        let completion = try ClaudeCodeClient.parse(Data(Self.ok.utf8))
        #expect(completion.content == #"{"word":"ok"}"#)
        #expect(completion.finishReason == "stop")
        #expect(completion.usage?.promptTokens == 1111)
        #expect(completion.usage?.completionTokens == 9)
        #expect(completion.usage?.cost == nil)
    }

    @Test func resultTextIsContentWithoutASchema() throws {
        let completion = try ClaudeCodeClient.parse(Data(Self.plainText.utf8))
        #expect(completion.content == "Hello there")
    }

    @Test func maxTokensBecomesLength() throws {
        #expect(try ClaudeCodeClient.parse(Data(Self.truncated.utf8)).finishReason == "length")
    }

    @Test func notLoggedInIsNotSignedIn() {
        #expect(throws: ProviderError.notSignedIn(tool: "Claude Code")) {
            _ = try ClaudeCodeClient.parse(Data(Self.notLoggedIn.utf8))
        }
    }

    @Test func otherErrorsCarryTheResultText() {
        let body = #"{"is_error":true,"result":"Rate limit reached","type":"result"}"#
        #expect(throws: ProviderError.backend("Rate limit reached")) {
            _ = try ClaudeCodeClient.parse(Data(body.utf8))
        }
    }

    @Test func garbageIsABackendError() {
        #expect(throws: ProviderError.self) { _ = try ClaudeCodeClient.parse(Data("not json".utf8)) }
    }

    @Test func completeSpawnsWithPromptOnStdin() async throws {
        let runner = MockProcessRunner(stdout: Self.ok)
        let completion = try await client(runner).complete(
            messages: [ChatMessage(role: "system", content: "Sys"), ChatMessage(role: "user", content: "Say ok")],
            model: "haiku", responseFormat: .jsonSchema(name: "w", schemaJSON: Self.schema),
            maxTokens: 100, temperature: 0.2, reasoning: nil)
        #expect(completion.content == #"{"word":"ok"}"#)
        let call = try #require(runner.calls.first)
        #expect(call.executable.path == "/fake/claude")
        #expect(call.stdinText == "Say ok")
        #expect(call.arguments.contains("--system-prompt"))
        #expect(call.environment["HOME"] == "/Users/test")
        #expect(call.timeout == 42)
    }

    @Test func nonZeroExitWithEmptyStdoutReportsStderr() async {
        let runner = MockProcessRunner(results: [.success(ProcessResult(
            stdout: Data(), stderr: Data("boom\n".utf8), status: 1))])
        await #expect(throws: ProviderError.backend("boom")) {
            _ = try await client(runner).complete(
                messages: [ChatMessage(role: "user", content: "x")], model: "haiku",
                responseFormat: .none, maxTokens: 10, temperature: nil, reasoning: nil)
        }
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter ClaudeCodeClientTests`
Expected: compile errors.

- [ ] **Step 3: Write the client**

```swift
// Sources/KleothCore/Providers/ClaudeCodeClient.swift
import Foundation

/// Runs the user's own installed Claude Code binary in print mode as a chat
/// backend. Kleoth never sees a token: the binary signs in on its own.
///
/// Every call is isolated from the user's Claude Code setup — no settings, no
/// MCP servers, no tools, no session file — because those otherwise ride
/// along as ~150k cached input tokens per call (measured 2026-09-15: 7 s and
/// 154k tokens with the defaults vs 1.7 s and 1.1k tokens isolated).
public struct ClaudeCodeClient: ChatCompleting {
    public static let toolName = "Claude Code"

    public let executable: URL
    public let runner: any ProcessRunner
    public let environment: [String: String]
    /// Ceiling for one call. Summaries can take minutes on a long transcript;
    /// the dictation polisher wraps its call in its own 30 s budget anyway.
    public let timeout: TimeInterval

    public init(executable: URL, runner: any ProcessRunner, environment: [String: String], timeout: TimeInterval = 600) {
        self.executable = executable
        self.runner = runner
        self.environment = environment
        self.timeout = timeout
    }

    // MARK: - ChatCompleting

    public func complete(
        messages: [ChatMessage], model: String, responseFormat: OpenRouterResponseFormat,
        maxTokens: Int, temperature: Double?, reasoning: OpenRouterReasoning?
    ) async throws -> ChatCompletion {
        let flat = ChatMessage.flattenForSingleTurn(messages)
        let arguments = Self.arguments(model: model, responseFormat: responseFormat, systemPrompt: flat.system)
        let prompt = Self.prompt(for: flat.prompt, responseFormat: responseFormat)
        let result = try await runner.run(
            executable: executable, arguments: arguments, stdin: Data(prompt.utf8),
            environment: environment, timeout: timeout)
        if result.stdout.isEmpty {
            let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProviderError.backend(stderr.isEmpty ? "\(Self.toolName) exited with status \(result.status)." : stderr)
        }
        return try Self.parse(result.stdout)
    }

    // MARK: - Request shaping

    /// The argument list. `--tools ""` disables every tool, `--setting-sources ""`
    /// skips the user's settings/CLAUDE.md, `--strict-mcp-config` with an empty
    /// config loads no MCP server, `--system-prompt` REPLACES Claude Code's own
    /// (coding-assistant) system prompt with ours.
    public static func arguments(model: String, responseFormat: OpenRouterResponseFormat, systemPrompt: String?) -> [String] {
        var args = [
            "-p", "--output-format", "json", "--tools", "", "--no-session-persistence",
            "--setting-sources", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
        ]
        if !model.isEmpty { args += ["--model", model] }
        if let systemPrompt, !systemPrompt.isEmpty { args += ["--system-prompt", systemPrompt] }
        if case let .jsonSchema(_, schemaJSON) = responseFormat { args += ["--json-schema", schemaJSON] }
        return args
    }

    /// The stdin prompt. A plain `json_object` request has no flag, so the
    /// instruction is appended in words.
    public static func prompt(for prompt: String, responseFormat: OpenRouterResponseFormat) -> String {
        if case .jsonObject = responseFormat {
            return prompt + "\n\nReturn only a JSON object, no prose."
        }
        return prompt
    }

    // MARK: - Response parsing

    private struct Output: Decodable {
        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
        }
        let isError: Bool?
        let result: String?
        let stopReason: String?
        let usage: Usage?
    }

    /// `structured_output` (a schema was given) is re-serialized as the
    /// content; otherwise `result`. `is_error` becomes a `ProviderError`.
    public static func parse(_ stdout: Data) throws -> ChatCompletion {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let output = try? decoder.decode(Output.self, from: stdout),
              let object = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] else {
            let text = String(decoding: stdout.prefix(300), as: UTF8.self)
            throw ProviderError.backend("\(toolName) returned unreadable output: \(text)")
        }
        if output.isError == true {
            let message = output.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "\(toolName) failed."
            if message.localizedCaseInsensitiveContains("not logged in") {
                throw ProviderError.notSignedIn(tool: toolName)
            }
            throw ProviderError.backend(message)
        }
        let content: String
        if let structured = object["structured_output"],
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]) {
            content = String(decoding: data, as: UTF8.self)
        } else {
            content = output.result ?? ""
        }
        let finish = output.stopReason == "max_tokens" ? "length" : "stop"
        let usage = ChatUsage(promptTokens: output.usage?.inputTokens, completionTokens: output.usage?.outputTokens, cost: nil)
        return ChatCompletion(content: content, usage: usage, finishReason: finish)
    }
}
```

- [ ] **Step 4: Run the suite**

Run: `swift test --filter ClaudeCodeClientTests`
Expected: 11 green. Note `structuredOutputIsReserializedAsContent` depends on `.sortedKeys` — a one-key object either way.

- [ ] **Step 5: Commit**

```bash
git add Sources/KleothCore/Providers/ClaudeCodeClient.swift Tests/KleothCoreTests/ClaudeCodeClientTests.swift
git commit -m "Core: ClaudeCodeClient — isolated claude -p with JSON schema on stdin"
```

---

### Task 7: `CodexClient`

**Files:**
- Create: `Sources/KleothCore/Providers/CodexClient.swift`
- Test: `Tests/KleothCoreTests/CodexClientTests.swift`

**Interfaces:**
- Consumes: `ChatCompleting`, `ProcessRunner`, `ProviderError`, `ChatMessage.flattenForSingleTurn`.
- Produces: `struct CodexClient: ChatCompleting { init(executable: URL, runner: any ProcessRunner, environment: [String: String], scratchDirectory: URL, timeout: TimeInterval = 600); static let toolName = "Codex"; static func arguments(model:schemaFile:workingDirectory:) -> [String]; static func prompt(system:prompt:responseFormat:) -> String; static func parse(_ stdout: Data) throws -> ChatCompletion }`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/KleothCoreTests/CodexClientTests.swift
import Testing
import Foundation
@testable import KleothCore

@Suite struct CodexClientTests {
    static let ok = """
    {"type":"thread.started","thread_id":"01a0"}
    {"type":"turn.started"}
    {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"{\\"word\\":\\"ok\\"}"}}
    {"type":"turn.completed","usage":{"input_tokens":13760,"cached_input_tokens":0,"output_tokens":15,"reasoning_output_tokens":0}}
    """
    static let refusedModel = """
    {"type":"thread.started","thread_id":"01a0"}
    {"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata for `gpt-5-mini` not found."}}
    {"type":"turn.started"}
    {"type":"error","message":"{\\"type\\":\\"error\\",\\"status\\":400,\\"error\\":{\\"type\\":\\"invalid_request_error\\",\\"message\\":\\"The 'gpt-5-mini' model is not supported when using Codex with a ChatGPT account.\\"}}"}
    {"type":"turn.failed","error":{"message":"{\\"type\\":\\"error\\",\\"status\\":400,\\"error\\":{\\"type\\":\\"invalid_request_error\\",\\"message\\":\\"The 'gpt-5-mini' model is not supported when using Codex with a ChatGPT account.\\"}}"}}
    """

    static let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("kleoth-codex-tests", isDirectory: true)

    func client(_ runner: MockProcessRunner) -> CodexClient {
        CodexClient(executable: URL(fileURLWithPath: "/fake/codex"), runner: runner,
                    environment: ["HOME": "/Users/test"], scratchDirectory: Self.scratch, timeout: 42)
    }

    @Test func argumentsAreHeadlessAndSandboxed() {
        let schema = URL(fileURLWithPath: "/tmp/s.json")
        let args = CodexClient.arguments(model: "o3", schemaFile: schema, workingDirectory: URL(fileURLWithPath: "/tmp/w"))
        #expect(args == [
            "exec", "--json", "--skip-git-repo-check", "-s", "read-only", "--ephemeral", "--color", "never",
            "-C", "/tmp/w", "-m", "o3", "--output-schema", "/tmp/s.json", "-",
        ])
        let noModel = CodexClient.arguments(model: "", schemaFile: nil, workingDirectory: URL(fileURLWithPath: "/tmp/w"))
        #expect(!noModel.contains("-m"))
        #expect(!noModel.contains("--output-schema"))
        #expect(noModel.last == "-")
    }

    @Test func promptLeadsWithTheSystemText() {
        let text = CodexClient.prompt(system: "Be terse.", prompt: "Summarize.", responseFormat: .none)
        #expect(text == "Be terse.\n\n---\n\nSummarize.")
        let json = CodexClient.prompt(system: nil, prompt: "Hi", responseFormat: .jsonObject)
        #expect(json == "Hi\n\nReturn only a JSON object, no prose.")
    }

    @Test func lastAgentMessageIsTheContent() throws {
        let completion = try CodexClient.parse(Data(Self.ok.utf8))
        #expect(completion.content == #"{"word":"ok"}"#)
        #expect(completion.usage?.promptTokens == 13760)
        #expect(completion.usage?.completionTokens == 15)
        #expect(completion.finishReason == "stop")
    }

    @Test func turnFailedIsABackendErrorWithTheInnerMessage() {
        #expect(throws: ProviderError.backend("The 'gpt-5-mini' model is not supported when using Codex with a ChatGPT account.")) {
            _ = try CodexClient.parse(Data(Self.refusedModel.utf8))
        }
    }

    @Test func noAgentMessageIsAnError() {
        let body = #"{"type":"thread.started","thread_id":"x"}"# + "\n" + #"{"type":"turn.completed","usage":{}}"#
        #expect(throws: ProviderError.self) { _ = try CodexClient.parse(Data(body.utf8)) }
    }

    @Test func completeWritesTheSchemaFileAndCleansUp() async throws {
        let runner = MockProcessRunner(stdout: Self.ok)
        let completion = try await client(runner).complete(
            messages: [ChatMessage(role: "system", content: "Sys"), ChatMessage(role: "user", content: "Say ok")],
            model: "", responseFormat: .jsonSchema(name: "w", schemaJSON: #"{"type":"object"}"#),
            maxTokens: 10, temperature: nil, reasoning: nil)
        #expect(completion.content == #"{"word":"ok"}"#)
        let call = try #require(runner.calls.first)
        #expect(call.stdinText == "Sys\n\n---\n\nSay ok")
        let schemaIndex = try #require(call.arguments.firstIndex(of: "--output-schema"))
        let schemaPath = call.arguments[schemaIndex + 1]
        #expect(schemaPath.hasPrefix(Self.scratch.path))
        #expect(!FileManager.default.fileExists(atPath: schemaPath))   // deleted after the call
        #expect(call.arguments[call.arguments.firstIndex(of: "-C")! + 1] == Self.scratch.path)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter CodexClientTests`
Expected: compile errors.

- [ ] **Step 3: Write the client**

```swift
// Sources/KleothCore/Providers/CodexClient.swift
import Foundation

/// Runs the user's installed Codex CLI headlessly as a chat backend. Summaries
/// only: a trivial call takes ~12 s and ~14k input tokens (measured
/// 2026-09-15), far outside the dictation budget.
///
/// Codex has no system-prompt flag, so the system text leads the stdin
/// prompt; the JSON schema goes through `--output-schema <file>`, written to
/// `scratchDirectory` for the call and deleted afterwards. `-C` points the
/// sandbox at that same scratch directory so nothing of the user's is in scope.
public struct CodexClient: ChatCompleting {
    public static let toolName = "Codex"

    public let executable: URL
    public let runner: any ProcessRunner
    public let environment: [String: String]
    public let scratchDirectory: URL
    public let timeout: TimeInterval

    public init(executable: URL, runner: any ProcessRunner, environment: [String: String], scratchDirectory: URL, timeout: TimeInterval = 600) {
        self.executable = executable
        self.runner = runner
        self.environment = environment
        self.scratchDirectory = scratchDirectory
        self.timeout = timeout
    }

    // MARK: - ChatCompleting

    public func complete(
        messages: [ChatMessage], model: String, responseFormat: OpenRouterResponseFormat,
        maxTokens: Int, temperature: Double?, reasoning: OpenRouterReasoning?
    ) async throws -> ChatCompletion {
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        var schemaFile: URL?
        if case let .jsonSchema(_, schemaJSON) = responseFormat {
            let file = scratchDirectory.appendingPathComponent("schema-\(UUID().uuidString).json")
            try Data(schemaJSON.utf8).write(to: file)
            schemaFile = file
        }
        defer { if let schemaFile { try? FileManager.default.removeItem(at: schemaFile) } }

        let flat = ChatMessage.flattenForSingleTurn(messages)
        let prompt = Self.prompt(system: flat.system, prompt: flat.prompt, responseFormat: responseFormat)
        let result = try await runner.run(
            executable: executable,
            arguments: Self.arguments(model: model, schemaFile: schemaFile, workingDirectory: scratchDirectory),
            stdin: Data(prompt.utf8), environment: environment, timeout: timeout)
        if result.stdout.isEmpty {
            let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProviderError.backend(stderr.isEmpty ? "\(Self.toolName) exited with status \(result.status)." : stderr)
        }
        return try Self.parse(result.stdout)
    }

    // MARK: - Request shaping

    public static func arguments(model: String, schemaFile: URL?, workingDirectory: URL) -> [String] {
        var args = [
            "exec", "--json", "--skip-git-repo-check", "-s", "read-only", "--ephemeral", "--color", "never",
            "-C", workingDirectory.path,
        ]
        if !model.isEmpty { args += ["-m", model] }
        if let schemaFile { args += ["--output-schema", schemaFile.path] }
        args.append("-")
        return args
    }

    public static func prompt(system: String?, prompt: String, responseFormat: OpenRouterResponseFormat) -> String {
        var text = prompt
        if let system, !system.isEmpty { text = system + "\n\n---\n\n" + text }
        if case .jsonObject = responseFormat { text += "\n\nReturn only a JSON object, no prose." }
        return text
    }

    // MARK: - Response parsing

    /// JSONL: the last `item.completed` whose item is an `agent_message` is the
    /// answer; `turn.failed` / `error` lines are failures (their message is
    /// itself a JSON envelope — the inner `error.message` is extracted).
    public static func parse(_ stdout: Data) throws -> ChatCompletion {
        var content: String?
        var promptTokens: Int?
        var completionTokens: Int?
        var failure: String?
        for line in stdout.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            switch type {
            case "item.completed":
                if let item = object["item"] as? [String: Any], item["type"] as? String == "agent_message",
                   let text = item["text"] as? String {
                    content = text
                }
            case "turn.completed":
                let usage = object["usage"] as? [String: Any]
                promptTokens = usage?["input_tokens"] as? Int
                completionTokens = usage?["output_tokens"] as? Int
            case "turn.failed":
                let error = object["error"] as? [String: Any]
                failure = innerMessage(error?["message"] as? String) ?? failure
            case "error":
                failure = innerMessage(object["message"] as? String) ?? failure
            default:
                break
            }
        }
        if let failure { throw ProviderError.backend(failure) }
        guard let content else {
            throw ProviderError.backend("\(toolName) returned no answer.")
        }
        return ChatCompletion(
            content: content,
            usage: ChatUsage(promptTokens: promptTokens, completionTokens: completionTokens, cost: nil),
            finishReason: "stop")
    }

    /// `{"type":"error","status":400,"error":{"message":"…"}}` → the inner message;
    /// a plain string is returned as is.
    static func innerMessage(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let message = object["message"] as? String { return message }
        }
        return raw
    }
}
```

- [ ] **Step 4: Run the suite**

Run: `swift test --filter CodexClientTests`
Expected: 6 green.

- [ ] **Step 5: Commit**

```bash
git add Sources/KleothCore/Providers/CodexClient.swift Tests/KleothCoreTests/CodexClientTests.swift
git commit -m "Core: CodexClient — codex exec --json with an output schema file"
```

---

### Task 8: `LocalModelList`, `ProviderDetector`, `ProviderFactory`

**Files:**
- Create: `Sources/KleothCore/Providers/LocalModelList.swift`
- Create: `Sources/KleothCore/Providers/ProviderDetector.swift`
- Create: `Sources/KleothCore/Providers/ProviderFactory.swift`
- Test: `Tests/KleothCoreTests/ProviderDetectorTests.swift`, `Tests/KleothCoreTests/ProviderFactoryTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–7.
- Produces: `enum LocalModelList { static func fetch(baseURL:apiKey:transport:) async throws -> [String] }`; `actor ProviderDetector { struct Probes; init(probes: Probes, cacheTTL: TimeInterval = 60); func snapshot(settings: ProviderSettings, openRouterKey: String?) async -> ProviderSnapshot; func refresh() }` with `Probes.standard(locator:runner:transport:apple:)`; `struct ProviderFactory { init(settings:openRouterKey:transport:runner:locator:appleClient:); struct Selection { provider, model, fellThroughFrom }; func select(task:snapshot:) -> Result<Selection, ProviderError>; func client(for:) throws -> any ChatCompleting; func summarizer(for:) throws -> Summarizer; func polisher(for:timeout:) throws -> DictationPolisher }`; `ProviderError.from(provider:reason:url:)`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/KleothCoreTests/ProviderDetectorTests.swift
import Testing
import Foundation
@testable import KleothCore

@Suite struct ProviderDetectorTests {
    static func probes(
        local: @escaping @Sendable (URL) async -> Result<[String], Error> = { _ in .failure(URLError(.cannotConnectToHost)) },
        claude: @escaping @Sendable () async -> ProviderAvailability = { .unavailable(reason: "Not installed") },
        codex: @escaping @Sendable () async -> ProviderAvailability = { .unavailable(reason: "Not installed") },
        apple: @escaping @Sendable () async -> ProviderAvailability = { .unavailable(reason: "Needs macOS 26") }
    ) -> ProviderDetector.Probes {
        ProviderDetector.Probes(localServer: local, claudeCode: claude, codex: codex, apple: apple)
    }

    @Test func snapshotCoversEveryProvider() async {
        let detector = ProviderDetector(probes: Self.probes(
            local: { _ in .success(["llama3", "qwen3"]) },
            claude: { .available(detail: "Claude Code 2.1.272 · signed in") }))
        let snap = await detector.snapshot(settings: ProviderSettings(), openRouterKey: "test-key")
        #expect(snap.count == AIProvider.allCases.count)
        #expect(snap[.localServer] == .available(detail: "localhost:11434 · 2 models", models: ["llama3", "qwen3"]))
        #expect(snap[.claudeCode] == .available(detail: "Claude Code 2.1.272 · signed in"))
        #expect(snap[.codex] == .unavailable(reason: "Not installed"))
        #expect(snap[.openRouter] == .available(detail: "API key set"))
        #expect(snap[.appleOnDevice] == .unavailable(reason: "Needs macOS 26"))
    }

    @Test func noKeyAndNoServer() async {
        let detector = ProviderDetector(probes: Self.probes())
        let snap = await detector.snapshot(settings: ProviderSettings(), openRouterKey: nil)
        #expect(snap[.openRouter] == .unavailable(reason: "No API key"))
        #expect(snap[.localServer] == .unavailable(reason: "No server at http://localhost:11434"))
    }

    @Test func snapshotIsCachedUntilRefreshOrInputChange() async {
        let counter = Counter()
        let detector = ProviderDetector(probes: Self.probes(local: { _ in
            await counter.bump()
            return .success(["m"])
        }))
        _ = await detector.snapshot(settings: ProviderSettings(), openRouterKey: nil)
        _ = await detector.snapshot(settings: ProviderSettings(), openRouterKey: nil)
        #expect(await counter.value == 1)
        var other = ProviderSettings()
        other.localServerURL = URL(string: "http://localhost:1234/v1")!
        _ = await detector.snapshot(settings: other, openRouterKey: nil)
        #expect(await counter.value == 2)
        await detector.refresh()
        _ = await detector.snapshot(settings: other, openRouterKey: nil)
        #expect(await counter.value == 3)
    }

    @Test func localModelListDecodesTheOpenAIShape() async throws {
        let transport = MockTransport(json: #"{"object":"list","data":[{"id":"llama3:8b","object":"model"},{"id":"qwen3","object":"model"}]}"#)
        let models = try await LocalModelList.fetch(baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: nil, transport: transport)
        #expect(models == ["llama3:8b", "qwen3"])
        #expect(transport.recordedRequests[0].url?.absoluteString == "http://localhost:11434/v1/models")
    }

    actor Counter {
        var value = 0
        func bump() { value += 1 }
    }
}
```

```swift
// Tests/KleothCoreTests/ProviderFactoryTests.swift
import Testing
import Foundation
@testable import KleothCore

@Suite struct ProviderFactoryTests {
    static func factory(settings: ProviderSettings = ProviderSettings(), key: String? = nil) -> ProviderFactory {
        ProviderFactory(
            settings: settings, openRouterKey: key, transport: MockTransport(json: "{}"),
            runner: MockProcessRunner(stdout: ""),
            locator: ToolLocator(searchDirectories: [URL(fileURLWithPath: "/nonexistent")]),
            appleClient: nil)
    }

    static func snapshot(_ entries: ProviderSnapshot) -> ProviderSnapshot {
        var snap: ProviderSnapshot = [:]
        for provider in AIProvider.allCases { snap[provider] = entries[provider] ?? .unavailable(reason: "Not installed") }
        return snap
    }

    @Test func selectUsesTheStoredOrDefaultModel() throws {
        var settings = ProviderSettings()
        settings = settings.settingModel("opus", for: .summary, on: .claudeCode)
        let factory = Self.factory(settings: settings)
        let snap = Self.snapshot([.claudeCode: .available(detail: "ok")])
        let selection = try factory.select(task: .summary, snapshot: snap).get()
        #expect(selection == ProviderFactory.Selection(provider: .claudeCode, model: "opus", fellThroughFrom: nil))
        let dictation = try factory.select(task: .dictation, snapshot: snap).get()
        #expect(dictation.model == "haiku")
    }

    @Test func localServerDefaultsToItsFirstModel() throws {
        let factory = Self.factory()
        let snap = Self.snapshot([.localServer: .available(detail: "x", models: ["qwen3", "llama3"])])
        #expect(try factory.select(task: .summary, snapshot: snap).get().model == "qwen3")
        let empty = Self.snapshot([.localServer: .available(detail: "x", models: [])])
        #expect(factory.select(task: .summary, snapshot: empty)
                == .failure(.backend("The local server lists no models — run `ollama pull <model>` first.")))
    }

    @Test func nothingAvailableIsNoProvider() {
        #expect(Self.factory().select(task: .summary, snapshot: Self.snapshot([:])) == .failure(.noProvider))
    }

    @Test func unavailableExplicitPickMapsToTheRightError() {
        var settings = ProviderSettings()
        settings.pick = .claudeCode
        let notInstalled = Self.factory(settings: settings)
        #expect(notInstalled.select(task: .summary, snapshot: Self.snapshot([:])) == .failure(.notInstalled(tool: "Claude Code")))
        let notSignedIn = Self.snapshot([.claudeCode: .unavailable(reason: "Not signed in")])
        #expect(notInstalled.select(task: .summary, snapshot: notSignedIn) == .failure(.notSignedIn(tool: "Claude Code")))
        settings.pick = .localServer
        let down = Self.factory(settings: settings)
        #expect(down.select(task: .summary, snapshot: Self.snapshot([:]))
                == .failure(.unreachable(url: ProviderSettings.defaultLocalServerURL)))
    }

    @Test func clientsAreBuiltPerProvider() throws {
        let factory = Self.factory(key: "test-key")
        #expect(try factory.client(for: .openRouter) is OpenRouterClient)
        #expect(try factory.client(for: .localServer) is OpenAICompatibleClient)
        #expect(throws: ProviderError.notInstalled(tool: "Claude Code")) { _ = try factory.client(for: .claudeCode) }
        #expect(throws: ProviderError.notInstalled(tool: "Codex")) { _ = try factory.client(for: .codex) }
        #expect(throws: ProviderError.unsupported("Apple on-device is not available.")) { _ = try factory.client(for: .appleOnDevice) }
        let noKey = Self.factory()
        #expect(throws: ProviderError.noProvider) { _ = try noKey.client(for: .openRouter) }
    }

    @Test func polisherFallbackModelOnlyOnOpenRouter() throws {
        let factory = Self.factory(key: "test-key")
        let router = try factory.polisher(for: .init(provider: .openRouter, model: "m", fellThroughFrom: nil))
        #expect(router.fallbackModel == DictationDefaults.fallbackPolishModel)
        #expect(router.model == "m")
        let local = try factory.polisher(for: .init(provider: .localServer, model: "qwen3", fellThroughFrom: nil))
        #expect(local.fallbackModel == nil)
        let summarizer = try factory.summarizer(for: .init(provider: .localServer, model: "qwen3", fellThroughFrom: nil))
        #expect(summarizer.model == "qwen3")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter "ProviderDetectorTests|ProviderFactoryTests"`
Expected: compile errors.

- [ ] **Step 3: Write `LocalModelList`**

```swift
// Sources/KleothCore/Providers/LocalModelList.swift
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `GET <base>/models` on an OpenAI-compatible server → model ids. Used by the
/// detector (is anything listening? what does it serve?) and the Settings picker.
public enum LocalModelList {
    private struct Response: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]?
    }

    public static func fetch(baseURL: URL, apiKey: String?, transport: HTTPTransport) async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await transport.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw OpenRouterError.httpError(status: status, bodySnippet: String(decoding: data.prefix(200), as: UTF8.self))
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return (decoded.data ?? []).map(\.id)
    }
}
```

- [ ] **Step 4: Write `ProviderDetector`**

```swift
// Sources/KleothCore/Providers/ProviderDetector.swift
import Foundation

/// Finds out what is usable right now: a key, a server answering, a CLI that
/// is installed AND signed in, Apple Intelligence on. Probes are injected so
/// tests never touch the filesystem or the network; results are cached for
/// `cacheTTL` (the dictation path resolves on every run and must not pay a
/// server probe each time).
public actor ProviderDetector {
    public struct Probes: Sendable {
        /// Model ids served at the URL, or the connection error.
        public var localServer: @Sendable (URL) async -> Result<[String], Error>
        public var claudeCode: @Sendable () async -> ProviderAvailability
        public var codex: @Sendable () async -> ProviderAvailability
        /// Supplied by the app (Foundation Models lives there); the core
        /// default reports "Needs macOS 26".
        public var apple: @Sendable () async -> ProviderAvailability

        public init(
            localServer: @escaping @Sendable (URL) async -> Result<[String], Error>,
            claudeCode: @escaping @Sendable () async -> ProviderAvailability,
            codex: @escaping @Sendable () async -> ProviderAvailability,
            apple: @escaping @Sendable () async -> ProviderAvailability = { .unavailable(reason: "Needs macOS 26") }
        ) {
            self.localServer = localServer
            self.claudeCode = claudeCode
            self.codex = codex
            self.apple = apple
        }

        /// The real probes: HTTP for the server, `claude auth status` and
        /// `codex login status` for the CLIs (10 s ceiling each).
        public static func standard(
            locator: ToolLocator,
            runner: any ProcessRunner,
            transport: HTTPTransport,
            apple: @escaping @Sendable () async -> ProviderAvailability = { .unavailable(reason: "Needs macOS 26") }
        ) -> Probes {
            Probes(
                localServer: { url in
                    do { return .success(try await LocalModelList.fetch(baseURL: url, apiKey: nil, transport: transport)) }
                    catch { return .failure(error) }
                },
                claudeCode: {
                    guard let exe = locator.find("claude") else { return .unavailable(reason: "Not installed") }
                    let env = locator.environment()
                    let version = await Self.version(of: exe, runner: runner, environment: env)
                    guard let status = try? await runner.run(executable: exe, arguments: ["auth", "status"], stdin: nil,
                                                             environment: env, timeout: 10),
                          let object = try? JSONSerialization.jsonObject(with: status.stdout) as? [String: Any],
                          object["loggedIn"] as? Bool == true else {
                        return .unavailable(reason: "Not signed in")
                    }
                    return .available(detail: "Claude Code \(version) · signed in")
                },
                codex: {
                    guard let exe = locator.find("codex") else { return .unavailable(reason: "Not installed") }
                    let env = locator.environment()
                    let version = await Self.version(of: exe, runner: runner, environment: env)
                    guard let status = try? await runner.run(executable: exe, arguments: ["login", "status"], stdin: nil,
                                                             environment: env, timeout: 10),
                          status.stdoutText.contains("Logged in") else {
                        return .unavailable(reason: "Not signed in")
                    }
                    return .available(detail: "Codex \(version) · signed in")
                },
                apple: apple)
        }

        /// First token of `<tool> --version` ("2.1.272 (Claude Code)" → "2.1.272";
        /// "codex-cli 0.153.4" → "0.153.4"). Empty when it cannot be read.
        static func version(of executable: URL, runner: any ProcessRunner, environment: [String: String]) async -> String {
            guard let result = try? await runner.run(executable: executable, arguments: ["--version"], stdin: nil,
                                                     environment: environment, timeout: 10) else { return "" }
            let tokens = result.stdoutText.split(whereSeparator: { $0 == " " || $0.isNewline })
            return tokens.first { $0.first?.isNumber == true }.map(String.init) ?? ""
        }
    }

    private struct CacheKey: Equatable {
        let localURL: URL
        let hasOpenRouterKey: Bool
    }

    private let probes: Probes
    private let cacheTTL: TimeInterval
    private var cached: (key: CacheKey, at: Date, snapshot: ProviderSnapshot)?

    public init(probes: Probes, cacheTTL: TimeInterval = 60) {
        self.probes = probes
        self.cacheTTL = cacheTTL
    }

    /// Drops the cache (Settings' Refresh, a settings change, `didBecomeActive`).
    public func refresh() {
        cached = nil
    }

    public func snapshot(settings: ProviderSettings, openRouterKey: String?) async -> ProviderSnapshot {
        let key = CacheKey(localURL: settings.localServerURL, hasOpenRouterKey: !(openRouterKey ?? "").isEmpty)
        if let cached, cached.key == key, Date().timeIntervalSince(cached.at) < cacheTTL {
            return cached.snapshot
        }
        async let local = probes.localServer(settings.localServerURL)
        async let claude = probes.claudeCode()
        async let codex = probes.codex()
        async let apple = probes.apple()

        var snap: ProviderSnapshot = [:]
        snap[.openRouter] = key.hasOpenRouterKey ? .available(detail: "API key set") : .unavailable(reason: "No API key")
        switch await local {
        case let .success(models):
            snap[.localServer] = .available(detail: "\(Self.hostLabel(settings.localServerURL)) · \(models.count) models", models: models)
        case .failure:
            snap[.localServer] = .unavailable(reason: "No server at \(Self.originLabel(settings.localServerURL))")
        }
        snap[.claudeCode] = await claude
        snap[.codex] = await codex
        snap[.appleOnDevice] = await apple
        cached = (key, Date(), snap)
        return snap
    }

    /// `localhost:11434`
    static func hostLabel(_ url: URL) -> String {
        var label = url.host ?? url.absoluteString
        if let port = url.port { label += ":\(port)" }
        return label
    }

    /// `http://localhost:11434`
    static func originLabel(_ url: URL) -> String {
        (url.scheme.map { "\($0)://" } ?? "") + hostLabel(url)
    }
}
```

- [ ] **Step 5: Write `ProviderFactory` and the error mapper**

```swift
// Sources/KleothCore/Providers/ProviderFactory.swift
import Foundation

/// Turns settings + a detector snapshot into a ready `Summarizer` /
/// `DictationPolisher`. The app (`AppConfig`) and the CLIs are its only callers.
public struct ProviderFactory: Sendable {
    /// The provider and model one call will run on.
    public struct Selection: Sendable, Equatable {
        public let provider: AIProvider
        public let model: String
        /// An explicit pick that could not do this task (Settings footer copy).
        public let fellThroughFrom: AIProvider?

        public init(provider: AIProvider, model: String, fellThroughFrom: AIProvider?) {
            self.provider = provider
            self.model = model
            self.fellThroughFrom = fellThroughFrom
        }
    }

    public var settings: ProviderSettings
    public var openRouterKey: String?
    public var transport: HTTPTransport
    public var runner: any ProcessRunner
    public var locator: ToolLocator
    /// The Foundation Models adapter, supplied by the app; nil elsewhere.
    public var appleClient: (any ChatCompleting)?

    public init(
        settings: ProviderSettings, openRouterKey: String?, transport: HTTPTransport,
        runner: any ProcessRunner, locator: ToolLocator, appleClient: (any ChatCompleting)?
    ) {
        self.settings = settings
        self.openRouterKey = openRouterKey
        self.transport = transport
        self.runner = runner
        self.locator = locator
        self.appleClient = appleClient
    }

    // MARK: - Selection

    public func select(task: AIProvider.Task, snapshot: ProviderSnapshot) -> Result<Selection, ProviderError> {
        switch ProviderResolver.resolve(task: task, pick: settings.pick, snapshot: snapshot) {
        case .none:
            return .failure(.noProvider)
        case let .unavailable(provider, reason):
            return .failure(ProviderError.from(provider: provider, reason: reason, url: settings.localServerURL))
        case let .provider(provider, fellThroughFrom):
            var model = settings.model(for: task, on: provider)
            if model.isEmpty, provider == .localServer {
                if case let .available(_, models)? = snapshot[.localServer] { model = models.first ?? "" }
                if model.isEmpty {
                    return .failure(.backend("The local server lists no models — run `ollama pull <model>` first."))
                }
            }
            return .success(Selection(provider: provider, model: model, fellThroughFrom: fellThroughFrom))
        }
    }

    // MARK: - Clients

    public func client(for provider: AIProvider) throws -> any ChatCompleting {
        switch provider {
        case .openRouter:
            guard let key = openRouterKey, !key.isEmpty else { throw ProviderError.noProvider }
            return OpenRouterClient(apiKey: key, transport: transport)
        case .localServer:
            return OpenAICompatibleClient(baseURL: settings.localServerURL, apiKey: settings.localServerKey, transport: transport)
        case .claudeCode:
            guard let exe = locator.find("claude") else { throw ProviderError.notInstalled(tool: ClaudeCodeClient.toolName) }
            return ClaudeCodeClient(executable: exe, runner: runner, environment: locator.environment())
        case .codex:
            guard let exe = locator.find("codex") else { throw ProviderError.notInstalled(tool: CodexClient.toolName) }
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("kleoth-codex", isDirectory: true)
            return CodexClient(executable: exe, runner: runner, environment: locator.environment(), scratchDirectory: scratch)
        case .appleOnDevice:
            guard let appleClient else { throw ProviderError.unsupported("Apple on-device is not available.") }
            return appleClient
        }
    }

    public func summarizer(for selection: Selection) throws -> Summarizer {
        Summarizer(client: try client(for: selection.provider), model: selection.model)
    }

    /// The OpenRouter fallback model (a second slug tried on an HTTP error)
    /// makes no sense on any other backend, so it is nil there.
    public func polisher(for selection: Selection, timeout: TimeInterval = DictationDefaults.polishTimeout) throws -> DictationPolisher {
        DictationPolisher(
            client: try client(for: selection.provider),
            model: selection.model,
            timeout: timeout,
            fallbackModel: selection.provider == .openRouter ? DictationDefaults.fallbackPolishModel : nil)
    }
}

public extension ProviderError {
    /// The detector's reason string for an explicitly picked, unusable
    /// provider → the typed error with the right copy.
    static func from(provider: AIProvider, reason: String, url: URL) -> ProviderError {
        switch provider {
        case .localServer:
            return .unreachable(url: url)
        case .openRouter:
            return .noProvider
        case .claudeCode, .codex:
            let tool = provider == .claudeCode ? ClaudeCodeClient.toolName : CodexClient.toolName
            if reason == "Not installed" { return .notInstalled(tool: tool) }
            if reason == "Not signed in" { return .notSignedIn(tool: tool) }
            return .backend(reason)
        case .appleOnDevice:
            return .unsupported(reason)
        }
    }
}
```

- [ ] **Step 6: Run the suite**

Run: `swift test`
Expected: green. `ProviderDetectorTests.snapshotIsCachedUntilRefreshOrInputChange` counts probe calls: 1 → 2 → 3.

- [ ] **Step 7: Commit**

```bash
git add Sources/KleothCore/Providers/LocalModelList.swift Sources/KleothCore/Providers/ProviderDetector.swift Sources/KleothCore/Providers/ProviderFactory.swift Tests/KleothCoreTests/ProviderDetectorTests.swift Tests/KleothCoreTests/ProviderFactoryTests.swift
git commit -m "Core: ProviderDetector snapshot with cache, ProviderFactory builds summarizer/polisher"
```

---

### Task 9: Provider fields on `MeetingMetadata` and `DictationLogEntry`

**Files:**
- Modify: `Sources/KleothCore/Models/MeetingMetadata.swift:4-43`
- Modify: `Sources/KleothCore/Dictation/DictationLogEntry.swift` (property, init, `CodingKeys`, decode, encode)
- Test: `Tests/KleothCoreTests/ProviderStorageTests.swift`

**Interfaces:**
- Produces: `MeetingMetadata.summaryProvider: String?` (stored `summary_provider`), `DictationLogEntry.polishProvider: String?` (stored `polish_provider`). Both nil = OpenRouter (pre-provider files).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/KleothCoreTests/ProviderStorageTests.swift
import Testing
import Foundation
@testable import KleothCore

@Suite struct ProviderStorageTests {
    static func snakeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func snakeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    @Test func metadataRoundTripsSummaryProvider() throws {
        var meta = MeetingMetadata(title: "T", date: "2026-09-16")
        meta.summaryProvider = AIProvider.claudeCode.rawValue
        let data = try Self.snakeEncoder().encode(meta)
        #expect(String(decoding: data, as: UTF8.self).contains(#""summary_provider":"claude-code""#))
        let back = try Self.snakeDecoder().decode(MeetingMetadata.self, from: data)
        #expect(back.summaryProvider == "claude-code")
    }

    @Test func legacyMetadataWithoutProviderDecodes() throws {
        let legacy = #"{"title":"T","date":"2026-01-01","participants":[],"consent_acknowledged":false}"#
        let meta = try Self.snakeDecoder().decode(MeetingMetadata.self, from: Data(legacy.utf8))
        #expect(meta.summaryProvider == nil)
    }

    @Test func logEntryRoundTripsPolishProvider() throws {
        let entry = DictationLogEntry(timestamp: "2026-09-16T10:00:00Z", rawText: "r", polishedText: "p",
                                      polishModel: "haiku", polishProvider: "claude-code")
        let data = try Self.snakeEncoder().encode(entry)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""polish_provider":"claude-code""#))
        let back = try Self.snakeDecoder().decode(DictationLogEntry.self, from: data)
        #expect(back.polishProvider == "claude-code")
        // Explicit encoding writes the key even when nil.
        let bare = DictationLogEntry(timestamp: "2026-09-16T10:00:00Z", rawText: "r", polishedText: "p")
        let bareText = String(decoding: try Self.snakeEncoder().encode(bare), as: UTF8.self)
        #expect(bareText.contains(#""polish_provider":null"#))
    }

    @Test func legacyLogRowWithoutProviderDecodes() throws {
        let legacy = #"{"id":"1","timestamp":"2026-09-03T15:14:09Z","raw_text":"r","polished_text":"p"}"#
        let entry = try Self.snakeDecoder().decode(DictationLogEntry.self, from: Data(legacy.utf8))
        #expect(entry.polishProvider == nil)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter ProviderStorageTests`
Expected: compile errors (`summaryProvider`, `polishProvider`).

- [ ] **Step 3: Add the fields**

`MeetingMetadata.swift` — after `transcriptTier`:
```swift
    /// Which ``AIProvider`` produced `summary.json` (its raw value, e.g.
    /// `"claude-code"`). `nil` for meetings summarized before providers
    /// existed — those were OpenRouter. Acronym-free → `summary_provider`.
    public var summaryProvider: String?
```
Add `summaryProvider: String? = nil` as the last `init` parameter and assign it. Synthesized `Codable` handles the rest (`MeetingStore` uses the snake_case strategies).

`DictationLogEntry.swift`:
- Property after `polishModel`: `/// The ``AIProvider`` raw value that ran the polish; nil = OpenRouter or no polish.` `public var polishProvider: String?`
- `init`: add `polishProvider: String? = nil` right after `polishModel` and assign it.
- `CodingKeys`: add `polishProvider` to the `case transcriptionModel, polishModel, durationSeconds` line.
- `init(from:)`: `polishProvider = try container.decodeIfPresent(String.self, forKey: .polishProvider)` after the `polishModel` line.
- `encode(to:)`: `try container.encode(polishProvider, forKey: .polishProvider)` after the `polishModel` line.

- [ ] **Step 4: Run the suite**

Run: `swift test`
Expected: green (existing `DictationLogStoreTests` still pass — they decode day files leniently).

- [ ] **Step 5: Commit**

```bash
git add Sources/KleothCore/Models/MeetingMetadata.swift Sources/KleothCore/Dictation/DictationLogEntry.swift Tests/KleothCoreTests/ProviderStorageTests.swift
git commit -m "Core: summary_provider on meta.json, polish_provider on dictation rows"
```

---

### Task 10: `KleothOnDevice` target — Apple Foundation Models adapter

**Files:**
- Modify: `app/Package.swift` (new target, `KleothApp` and `dictate` depend on it)
- Create: `app/Sources/KleothOnDevice/AppleOnDeviceClient.swift`

**Interfaces:**
- Consumes: `ChatCompleting`, `ChatCompletion`, `ProviderAvailability`, `ProviderError`, `ChatMessage.flattenForSingleTurn`, `DictationPrompt.schemaJSON` (the schema name is `"dictation_text"`, from `DictationPolisher.attempt`).
- Produces: `public struct AppleOnDeviceClient: ChatCompleting { public init(); public static func availability() -> ProviderAvailability; public static let maxPromptCharacters = 12_000 }`.

No unit test target exists in the app package; this task is verified by building and by the `dictate --provider apple` probe in Task 13.

- [ ] **Step 1: Add the target**

In `app/Package.swift`, after the `KleothPillUI` target:
```swift
        // Apple's on-device model (Foundation Models, macOS 26) as a
        // `ChatCompleting` backend for dictation polish. Its own target so the
        // framework is weak-linked in one place and nothing else in the app
        // imports it: the app's floor is 14.4, where the framework does not exist.
        .target(
            name: "KleothOnDevice",
            dependencies: [
                .product(name: "KleothCore", package: "kleoth-app"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])
            ]
        ),
```
Add `"KleothOnDevice",` to the `dependencies` of the `KleothApp` and `dictate` targets.

- [ ] **Step 2: Write the adapter**

```swift
// app/Sources/KleothOnDevice/AppleOnDeviceClient.swift
import Foundation
import KleothCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device language model behind ``ChatCompleting``. Dictation
/// polish only: the model's context is a fixed 4096 tokens, so a meeting
/// transcript never fits, and the only schema it answers is the polisher's
/// `dictation_text` (`{text, language}`), mirrored below as a `@Generable` type.
///
/// Nothing leaves the machine and no setup is needed beyond Apple
/// Intelligence being on — the "truly local" default for dictation on macOS 26.
public struct AppleOnDeviceClient: ChatCompleting {
    /// Roughly 3,500 tokens of Latin or ~1,700 of Cyrillic — refused up front
    /// rather than spending a call that `exceededContextWindowSize` would end.
    public static let maxPromptCharacters = 12_000

    public init() {}

    // MARK: - Availability

    public static func availability() -> ProviderAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available(detail: "Apple Intelligence on")
            case let .unavailable(reason):
                switch reason {
                case .deviceNotEligible:
                    return .unavailable(reason: "This Mac does not support Apple Intelligence")
                case .appleIntelligenceNotEnabled:
                    return .unavailable(reason: "Apple Intelligence is off (System Settings → Apple Intelligence & Siri)")
                case .modelNotReady:
                    return .unavailable(reason: "The Apple model is still downloading")
                @unknown default:
                    return .unavailable(reason: "Apple Intelligence is unavailable")
                }
            }
        }
        #endif
        return .unavailable(reason: "Needs macOS 26")
    }

    // MARK: - ChatCompleting

    public func complete(
        messages: [ChatMessage], model: String, responseFormat: OpenRouterResponseFormat,
        maxTokens: Int, temperature: Double?, reasoning: OpenRouterReasoning?
    ) async throws -> ChatCompletion {
        guard case let .jsonSchema(name, _) = responseFormat, name == "dictation_text" else {
            throw ProviderError.unsupported("Apple on-device can only clean up dictations.")
        }
        let flat = ChatMessage.flattenForSingleTurn(messages)
        guard flat.prompt.count + (flat.system?.count ?? 0) <= Self.maxPromptCharacters else {
            throw ProviderError.inputTooLong
        }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = LanguageModelSession(instructions: flat.system ?? "")
            let options = GenerationOptions(temperature: temperature ?? 0.2)
            do {
                let response = try await session.respond(to: flat.prompt, generating: PolishedText.self, options: options)
                let payload: [String: Any] = [
                    "text": response.content.text,
                    "language": response.content.language,
                ]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                return ChatCompletion(content: String(decoding: data, as: UTF8.self), usage: nil, finishReason: "stop")
            } catch let error as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error { throw ProviderError.inputTooLong }
                throw ProviderError.backend(error.localizedDescription)
            }
        }
        #endif
        throw ProviderError.unsupported("Apple on-device needs macOS 26.")
    }
}

#if canImport(FoundationModels)
/// The polisher's `dictation_text` schema (`DictationPrompt.schemaJSON`) as a
/// generable type. Keep the two in step: `text` + `language`.
@available(macOS 26, *)
@Generable
struct PolishedText {
    @Guide(description: "The cleaned-up text the speaker meant to type, in the same language they spoke.")
    var text: String
    @Guide(description: "BCP-47 code of the language the text is written in, e.g. en or ru.")
    var language: String
}
#endif
```

- [ ] **Step 3: Build and check the weak link**

Run: `rm -f app/.build/arm64-apple-macosx/debug/description.json; swift build --package-path app`
Expected: succeeds. Then `otool -L app/.build/debug/KleothApp | grep FoundationModels` — must print a line ending in `(weak)`. If it is not weak, the launch on macOS 14/15 would fail; check the `unsafeFlags` spelling.

If `GenerationOptions(temperature:)` or `respond(to:generating:options:)` does not compile against this SDK, open the framework interface (`xcrun swift-api-digester` is not needed: in Xcode, jump to definition of `LanguageModelSession.respond`) and adapt the labels — the shape is `respond(to: String, generating: T.Type, includeSchemaInPrompt: Bool = true, options: GenerationOptions = .init())`.

- [ ] **Step 4: Commit**

```bash
git add app/Package.swift app/Sources/KleothOnDevice/AppleOnDeviceClient.swift
git commit -m "App: KleothOnDevice — Apple Foundation Models as a dictation polish backend"
```

---

### Task 11: App wiring — Keychain keys, `AppConfig` factories, the six call sites, controller setters

**Files:**
- Create: `Sources/KleothCore/Providers/ProviderStatus.swift` (+ test `Tests/KleothCoreTests/ProviderStatusTests.swift`)
- Modify: `app/Sources/KleothApp/Keychain.swift:33-68` (four accounts)
- Modify: `app/Sources/KleothApp/AppConfig.swift` (overlay + detector + factories)
- Modify: `app/Sources/KleothApp/RecordingController.swift` — `summarizeLatestMeeting` (~315-340), `runPipeline` (~948-975), `runFullTranscription` (~1075-1136), `runOnDeviceTranscription` (~1296-1310), setters (~455-470), new `providerStatus`
- Modify: `app/Sources/KleothApp/Dictation/DictationController.swift:790-860`

**Interfaces:**
- Consumes: `ProviderFactory`, `ProviderDetector`, `ProviderSettings`, `AIProvider`, `AppleOnDeviceClient`, `MeetingMetadata.summaryProvider`, `DictationLogEntry.polishProvider`.
- Produces: `struct ProviderStatus: Sendable, Equatable { snapshot; summary: Result<ProviderFactory.Selection, ProviderError>; dictation: Result<…>; var footerText: String; var detectedNames: [String] }`; `Keychain.Account.aiProvider / localServerURL / localServerKey / aiModels`; `AppConfig.detector`, `AppConfig.factory(settings:credentials:)`, `AppConfig.makeSummarizer() async throws -> (Summarizer, ProviderFactory.Selection)`, `AppConfig.makePolisher() async throws -> (DictationPolisher, ProviderFactory.Selection)`, `AppConfig.providerStatus() async -> ProviderStatus`; `RecordingController.providerStatus: ProviderStatus?` (`@Published`), `refreshProviderStatus() async`, `updateAIProvider(_:)`, `updateLocalServerURL(_:)`, `updateLocalServerKey(_:)`, `updateProviderModel(_:for:on:)`.

- [ ] **Step 1: `ProviderStatus` with its test (core)**

```swift
// Tests/KleothCoreTests/ProviderStatusTests.swift
import Testing
@testable import KleothCore

@Suite struct ProviderStatusTests {
    @Test func footerNamesBothTasks() {
        let status = ProviderStatus(
            snapshot: [:],
            summary: .success(.init(provider: .claudeCode, model: "sonnet", fellThroughFrom: .appleOnDevice)),
            dictation: .success(.init(provider: .appleOnDevice, model: "apple-on-device", fellThroughFrom: nil)))
        #expect(status.footerText == "Summaries via Claude Code (Apple on-device cannot summarize) · Dictation via Apple on-device")
    }

    @Test func footerShowsErrors() {
        let status = ProviderStatus(snapshot: [:], summary: .failure(.noProvider), dictation: .failure(.notSignedIn(tool: "Claude Code")))
        #expect(status.footerText == "Summaries: No AI provider available — open Settings → Accounts. · Dictation: Claude Code is not signed in. Open a terminal, run `claude`, and sign in.")
    }

    @Test func detectedNamesListAvailableProvidersInAutoOrder() {
        let status = ProviderStatus(
            snapshot: [.openRouter: .available(detail: "k"), .claudeCode: .available(detail: "c"), .codex: .unavailable(reason: "x")],
            summary: .failure(.noProvider), dictation: .failure(.noProvider))
        #expect(status.detectedNames == ["Claude Code", "OpenRouter"])
    }
}
```

```swift
// Sources/KleothCore/Providers/ProviderStatus.swift
import Foundation

/// What Settings, the popover and onboarding show about the providers: the
/// snapshot plus the resolution for each task. Built by `AppConfig` /
/// `ProviderBootstrap`, displayed as `footerText`.
public struct ProviderStatus: Sendable, Equatable {
    public let snapshot: ProviderSnapshot
    public let summary: Result<ProviderFactory.Selection, ProviderError>
    public let dictation: Result<ProviderFactory.Selection, ProviderError>

    public init(snapshot: ProviderSnapshot,
                summary: Result<ProviderFactory.Selection, ProviderError>,
                dictation: Result<ProviderFactory.Selection, ProviderError>) {
        self.snapshot = snapshot
        self.summary = summary
        self.dictation = dictation
    }

    /// "Summaries via Claude Code (Apple on-device cannot summarize) · Dictation via Apple on-device"
    public var footerText: String {
        [Self.line("Summaries", summary, cannot: "summarize"),
         Self.line("Dictation", dictation, cannot: "clean up dictations")].joined(separator: " · ")
    }

    /// Display names of every available provider, in auto order (onboarding caption).
    public var detectedNames: [String] {
        AIProvider.autoOrder.filter { snapshot[$0]?.isAvailable ?? false }.map(\.displayName)
    }

    private static func line(_ task: String, _ result: Result<ProviderFactory.Selection, ProviderError>, cannot verb: String) -> String {
        switch result {
        case let .success(selection):
            var text = "\(task) via \(selection.provider.displayName)"
            if let from = selection.fellThroughFrom { text += " (\(from.displayName) cannot \(verb))" }
            return text
        case let .failure(error):
            return "\(task): \(error.localizedDescription)"
        }
    }
}
```
Run `swift test --filter ProviderStatusTests` → 3 green.

- [ ] **Step 2: Keychain accounts**

In `Keychain.Account` (after `inputDevice`):
```swift
        /// The AI provider pick: an `AIProvider` raw value, or "" / "auto" for
        /// Automatic (an explicit empty value overrides a `config.json` pick).
        /// New key: NOT in `legacyAccounts`.
        public static let aiProvider = "ai_provider"
        /// API root of the local OpenAI-compatible server (Ollama / LM Studio).
        public static let localServerURL = "local_server_url"
        /// Optional bearer token for that server.
        public static let localServerKey = "local_server_key"
        /// JSON map of per-provider, per-task models (`ProviderSettings.modelsJSON`).
        public static let aiModels = "ai_models"
```

- [ ] **Step 3: `AppConfig` overlay, detector and factories**

Add `import KleothOnDevice` at the top. In `mergeSettingsFromKeychain`, before the `merged.defaultModel = ModelCatalog.migrating(...)` line:
```swift
        // AI provider: an EMPTY stored pick is the user's explicit Automatic
        // and overrides any `config.json` pick (the `input_device` idiom).
        if let pick = Keychain.get(Keychain.Account.aiProvider) {
            merged.providerSettings.pick = AIProvider.parse(pick)
        }
        if let url = Keychain.get(Keychain.Account.localServerURL), let normalized = ProviderSettings.normalizeServerURL(url) {
            merged.providerSettings.localServerURL = normalized
        }
        if let key = Keychain.get(Keychain.Account.localServerKey) {
            merged.providerSettings.localServerKey = key.isEmpty ? nil : key
        }
        if let models = Keychain.get(Keychain.Account.aiModels), !models.isEmpty {
            merged.providerSettings.models = ProviderSettings.parseModels(models)
        }
```
Add to the enum:
```swift
    // MARK: - AI providers

    /// One detector for the whole app: its 60 s cache is what keeps a
    /// dictation from paying a server probe on every run.
    static let detector = ProviderDetector(probes: .standard(
        locator: .standard,
        runner: FoundationProcessRunner(),
        transport: URLSessionTransport(),
        apple: { AppleOnDeviceClient.availability() }))

    static func factory(settings: KleothCore.Settings, credentials: Credentials) -> ProviderFactory {
        ProviderFactory(
            settings: settings.providerSettings,
            openRouterKey: credentials.openRouterKey,
            transport: URLSessionTransport(),
            runner: FoundationProcessRunner(),
            locator: .standard,
            appleClient: AppleOnDeviceClient.availability().isAvailable ? AppleOnDeviceClient() : nil)
    }

    /// The summarizer for the current settings, or the `ProviderError` that
    /// says why there is none.
    static func makeSummarizer() async throws -> (Summarizer, ProviderFactory.Selection) {
        let settings = settings()
        let credentials = credentials()
        let factory = factory(settings: settings, credentials: credentials)
        let snapshot = await detector.snapshot(settings: settings.providerSettings, openRouterKey: credentials.openRouterKey)
        let selection = try factory.select(task: .summary, snapshot: snapshot).get()
        return (try factory.summarizer(for: selection), selection)
    }

    static func makePolisher() async throws -> (DictationPolisher, ProviderFactory.Selection) {
        let settings = settings()
        let credentials = credentials()
        let factory = factory(settings: settings, credentials: credentials)
        let snapshot = await detector.snapshot(settings: settings.providerSettings, openRouterKey: credentials.openRouterKey)
        let selection = try factory.select(task: .dictation, snapshot: snapshot).get()
        return (try factory.polisher(for: selection), selection)
    }

    static func providerStatus() async -> ProviderStatus {
        let settings = settings()
        let credentials = credentials()
        let factory = factory(settings: settings, credentials: credentials)
        let snapshot = await detector.snapshot(settings: settings.providerSettings, openRouterKey: credentials.openRouterKey)
        return ProviderStatus(
            snapshot: snapshot,
            summary: factory.select(task: .summary, snapshot: snapshot),
            dictation: factory.select(task: .dictation, snapshot: snapshot))
    }
```
`DictationPolisher`'s `transport` in `DictationController` had 30/60 s timeouts; the factory's `URLSessionTransport()` uses the default session. That is acceptable: the polisher's own `withTimeout(30)` bounds the call.

- [ ] **Step 4: `RecordingController` — status, setters, four sites**

Add after `credentials`:
```swift
    /// What the AI providers resolve to right now (Settings footer, popover,
    /// onboarding). Refreshed on init, after every provider setting change and
    /// when the app becomes active.
    @Published public private(set) var providerStatus: ProviderStatus?

    public func refreshProviderStatus() async {
        providerStatus = await AppConfig.providerStatus()
    }
```
In `init`, after `startWatchingOutputDir()`: `Task { await refreshProviderStatus() }`.

Setters, next to `updateDefaultModel`:
```swift
    /// Persists the AI provider pick ("auto" or an `AIProvider` raw value).
    public func updateAIProvider(_ raw: String) {
        let pick = AIProvider.parse(raw)
        Keychain.set(pick?.rawValue ?? "", Keychain.Account.aiProvider)
        settings.providerSettings.pick = pick
        providerSettingsChanged()
    }

    public func updateLocalServerURL(_ raw: String) {
        let url = ProviderSettings.normalizeServerURL(raw) ?? ProviderSettings.defaultLocalServerURL
        Keychain.set(url.absoluteString, Keychain.Account.localServerURL)
        settings.providerSettings.localServerURL = url
        providerSettingsChanged()
    }

    public func updateLocalServerKey(_ key: String) {
        Keychain.set(key, Keychain.Account.localServerKey)
        settings.providerSettings.localServerKey = key.isEmpty ? nil : key
        providerSettingsChanged()
    }

    /// Persists the model for `task` on `provider` (empty = the provider's default).
    public func updateProviderModel(_ model: String, for task: AIProvider.Task, on provider: AIProvider) {
        settings.providerSettings = settings.providerSettings.settingModel(model, for: task, on: provider)
        Keychain.set(settings.providerSettings.modelsJSON, Keychain.Account.aiModels)
        providerSettingsChanged()
    }

    private func providerSettingsChanged() {
        Task {
            await AppConfig.detector.refresh()
            await refreshProviderStatus()
        }
    }
```
Also in `updateOpenRouterKey`, append `providerSettingsChanged()` (a key appearing changes the snapshot).

`summarizeLatestMeeting` (~line 318): replace
```swift
        guard let key = credentials.openRouterKey, !key.isEmpty else {
            statusMessage = "Add an OpenRouter key in Settings to summarize."
            return
        }
```
with
```swift
        let summarizer: Summarizer
        let selection: ProviderFactory.Selection
        do {
            (summarizer, selection) = try await AppConfig.makeSummarizer()
        } catch {
            statusMessage = error.localizedDescription
            return
        }
```
and lower down replace `meta.model = settings.defaultModel` with `meta.model = selection.model` + `meta.summaryProvider = selection.provider.rawValue`, and delete the local `let summarizer = Summarizer(client: OpenRouterClient(...))`.

`runPipeline` (~948), `runFullTranscription` (~1075) and `runOnDeviceTranscription` (~1296): replace each
```swift
        var summarizer: Summarizer?
        if let openRouterKey = credentials.openRouterKey, !openRouterKey.isEmpty {
            summarizer = Summarizer(
                client: OpenRouterClient(apiKey: openRouterKey, transport: …),
                model: settings.defaultModel
            )
        }
        let canSummarize = (summarizer != nil)
```
with
```swift
        var summarizer: Summarizer?
        var summarySelection: ProviderFactory.Selection?
        do {
            let made = try await AppConfig.makeSummarizer()
            summarizer = made.0
            summarySelection = made.1
        } catch {
            log.notice("no summarizer: \(error.localizedDescription, privacy: .public)")
        }
        let canSummarize = (summarizer != nil)
```
then every `settings.defaultModel` in those three functions that feeds `metadata.model` / `model:` becomes `summarySelection?.model`, and next to each such assignment add `metadata.summaryProvider = summarySelection?.provider.rawValue` (in `runPipeline` the metadata is built with an initializer: pass `summaryProvider: summarySelection?.provider.rawValue`). Search the file for `defaultModel` afterwards: the only remaining uses must be `updateDefaultModel` and the Keychain overlay.

- [ ] **Step 5: `DictationController` — the polish site and the log row**

Replace (line ~795)
```swift
        } else if let openRouterKey = credentials.openRouterKey, !openRouterKey.isEmpty {
            phase = .polishing
            pill.show(.polishing)
            let polisher = DictationPolisher(
                client: OpenRouterClient(apiKey: openRouterKey, transport: transport),
                model: settings.dictationModel
            )
```
with
```swift
        } else if let made = try? await AppConfig.makePolisher() {
            let (polisher, selection) = made
            polishSelection = selection
            phase = .polishing
            pill.show(.polishing)
```
and the trailing
```swift
        } else {
            polish = .raw(text: rawText, reason: "No OpenRouter key — pasted the raw transcript.")
        }
```
with
```swift
        } else {
            let reason = (await Self.polishUnavailableReason()) ?? ProviderError.noProvider.localizedDescription
            polish = .raw(text: rawText, reason: "\(reason) — pasted the raw transcript.")
        }
```
plus, in the class, `private var polishSelection: ProviderFactory.Selection?` (reset to nil at the top of `run()` next to the other per-run state) and
```swift
    /// Why no polisher could be built, for the pill (`makePolisher` threw).
    private static func polishUnavailableReason() async -> String? {
        do { _ = try await AppConfig.makePolisher(); return nil } catch { return error.localizedDescription }
    }
```
Log row: `polishModel: polish.ranModel ? polishSelection?.model : nil,` and add `polishProvider: polish.ranModel ? polishSelection?.provider.rawValue : nil,` right after it. The `transport` property stays (Scribe uses it).

- [ ] **Step 6: Build, then grep for leftovers**

Run: `rm -f app/.build/arm64-apple-macosx/debug/description.json; swift build --package-path app 2>&1 | tail -20`
Expected: succeeds, zero warnings. Then:
```bash
grep -rn "OpenRouterClient(" app/Sources/KleothApp   # expected: no matches
grep -rn "openRouterKey" app/Sources/KleothApp | grep -v "AppConfig\|Keychain\|SettingsView\|updateOpenRouterKey\|credentials.openRouterKey = "
```
Expected for the second: nothing — every remaining read of the key goes through `AppConfig`.

- [ ] **Step 7: Commit**

```bash
git add Sources/KleothCore/Providers/ProviderStatus.swift Tests/KleothCoreTests/ProviderStatusTests.swift app/Sources/KleothApp/Keychain.swift app/Sources/KleothApp/AppConfig.swift app/Sources/KleothApp/RecordingController.swift app/Sources/KleothApp/Dictation/DictationController.swift
git commit -m "App: summaries and dictation polish go through ProviderFactory; provider keys in the Keychain"
```

---

### Task 12: Settings UI — provider section, provider-aware model pickers, onboarding caption

**Files:**
- Create: `app/Sources/KleothApp/Views/SettingsAIProviderSection.swift`
- Create: `app/Sources/KleothApp/Views/ProviderModelField.swift`
- Modify: `app/Sources/KleothApp/Views/SettingsView.swift` (state ~23-45, `pageSections` `.accounts`/`.meetings`/`.dictation`, `summarizationSection` ~361-375, `loadFromController` ~728-766, `commitAll` ~781-790)
- Modify: `app/Sources/KleothApp/Views/SettingsDictationSection.swift:15-70`
- Modify: `app/Sources/KleothApp/Views/OnboardingView.swift:307-335` (caption)

**Interfaces:**
- Consumes: `RecordingController.providerStatus / refreshProviderStatus / updateAIProvider / updateLocalServerURL / updateLocalServerKey / updateProviderModel`, `AIProvider.modelChoice`, `ProviderSnapshot`, `ProviderStatus.footerText / detectedNames`.
- Produces: `SettingsAIProviderSection(aiProvider:localServerURL:localServerKey:)`, `ProviderModelField(title:provider:task:model:serverModels:)`; `SettingsDictationSection` gains `provider: AIProvider`, `providerModel: Binding<String>`, `serverModels: [String]`.

- [ ] **Step 1: The provider section**

```swift
// app/Sources/KleothApp/Views/SettingsAIProviderSection.swift
import SwiftUI
import KleothCore

/// Settings → Accounts, top: which backend runs summaries and dictation
/// polish. One picker (Automatic + the five providers), the local server's
/// URL/key when relevant, a live status row per provider and a footer that
/// says what each task resolves to right now.
struct SettingsAIProviderSection: View {
    @EnvironmentObject private var controller: RecordingController
    @Binding var aiProvider: String
    @Binding var localServerURL: String
    @Binding var localServerKey: String

    private var status: ProviderStatus? { controller.providerStatus }

    var body: some View {
        Section {
            Picker("AI provider", selection: $aiProvider) {
                Text("Automatic").tag("auto")
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider.rawValue)
                }
            }
            .onChange(of: aiProvider) { _, newValue in controller.updateAIProvider(newValue) }

            if showsServerFields {
                TextField("Server URL", text: $localServerURL, prompt: Text(ProviderSettings.defaultLocalServerURL.absoluteString))
                    .onSubmit { controller.updateLocalServerURL(localServerURL) }
                SecureField("Server key (optional)", text: $localServerKey)
                    .onSubmit { controller.updateLocalServerKey(localServerKey) }
            }

            ForEach(AIProvider.allCases) { provider in
                LabeledContent(provider.displayName) {
                    Text(availabilityText(provider))
                        .foregroundStyle(isAvailable(provider) ? KleothPalette.successTint : .secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        } header: {
            HStack(spacing: KleothMetrics.spacingS) {
                Text("AI provider")
                Button {
                    Task {
                        await AppConfig.detector.refresh()
                        await controller.refreshProviderStatus()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Check again which tools and servers are available")
            }
        } footer: {
            Text(status?.footerText ?? "Checking installed AI tools…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            // Cheap: the detector caches for 60 s; this only picks up changes.
            while !Task.isCancelled {
                await controller.refreshProviderStatus()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// The URL/key fields show when the local server is picked or is what
    /// Automatic resolved to for either task.
    private var showsServerFields: Bool {
        if aiProvider == AIProvider.localServer.rawValue { return true }
        guard let status else { return false }
        for result in [status.summary, status.dictation] {
            if case let .success(selection) = result, selection.provider == .localServer { return true }
        }
        return false
    }

    private func isAvailable(_ provider: AIProvider) -> Bool {
        status?.snapshot[provider]?.isAvailable ?? false
    }

    private func availabilityText(_ provider: AIProvider) -> String {
        switch status?.snapshot[provider] {
        case let .available(detail, _): return detail
        case let .unavailable(reason): return reason
        case nil: return "…"
        }
    }
}
```

- [ ] **Step 2: The provider-aware model field**

```swift
// app/Sources/KleothApp/Views/ProviderModelField.swift
import SwiftUI
import KleothCore

/// The model control for a non-OpenRouter provider (OpenRouter keeps its
/// catalog picker in `SettingsView` / `SettingsDictationSection`). What it
/// renders follows `AIProvider.modelChoice`.
struct ProviderModelField: View {
    let title: String
    let provider: AIProvider
    let task: AIProvider.Task
    @Binding var model: String
    /// Ids the local server lists (`ProviderAvailability.available(models:)`).
    let serverModels: [String]
    @EnvironmentObject private var controller: RecordingController

    var body: some View {
        Group {
            switch provider.modelChoice {
            case let .aliases(list):
                Picker(title, selection: $model) {
                    ForEach(pinned(list), id: \.self) { Text(label($0)).tag($0) }
                }
            case .serverList:
                Picker(title, selection: $model) {
                    ForEach(pinned(serverModels), id: \.self) { Text($0).tag($0) }
                }
            case let .freeText(placeholder):
                TextField(title, text: $model, prompt: Text(placeholder))
                    .onSubmit { commit() }
            case .fixed:
                LabeledContent(title) { Text(provider.displayName).foregroundStyle(.secondary) }
            case .openRouterCatalog:
                EmptyView()   // never reached: the caller renders the catalog picker
            }
        }
        .onChange(of: model) { _, _ in commit() }
    }

    /// The current value always stays selectable (a server that stopped
    /// listing it, an alias typed by hand).
    private func pinned(_ list: [String]) -> [String] {
        model.isEmpty || list.contains(model) ? list : [model] + list
    }

    private func label(_ alias: String) -> String {
        alias == provider.defaultModel(for: task) ? "\(alias)  (default)" : alias
    }

    private func commit() {
        controller.updateProviderModel(model, for: task, on: provider)
    }
}
```

- [ ] **Step 3: `SettingsView` state, pages, load, commit**

State (next to `openRouterKey`):
```swift
    @State private var aiProvider: String = "auto"
    @State private var localServerURL: String = ""
    @State private var localServerKey: String = ""
    @State private var summaryProviderModel: String = ""
    @State private var dictationProviderModel: String = ""
```
Helpers on `SettingsView`:
```swift
    /// The provider each task resolves to (nil until the first status lands).
    private func resolvedProvider(_ task: AIProvider.Task) -> AIProvider? {
        guard let status = controller.providerStatus else { return nil }
        let result = task == .summary ? status.summary : status.dictation
        if case let .success(selection) = result { return selection.provider }
        return nil
    }

    private var serverModels: [String] {
        if case let .available(_, models)? = controller.providerStatus?.snapshot[.localServer] { return models }
        return []
    }
```
`pageSections`: `.accounts` → `SettingsAIProviderSection(aiProvider: $aiProvider, localServerURL: $localServerURL, localServerKey: $localServerKey)` FIRST, then `credentialsSection`, `usageSection`. `.dictation` → pass `provider: resolvedProvider(.dictation) ?? .openRouter, providerModel: $dictationProviderModel, serverModels: serverModels` to `SettingsDictationSection`.

`summarizationSection`: wrap the existing `Picker("Default model", …)` in
```swift
            let provider = resolvedProvider(.summary) ?? .openRouter
            if provider == .openRouter {
                Picker("Default model", selection: $selectedModel) { … unchanged … }
                .onChange(of: selectedModel) { … unchanged … }
            } else {
                ProviderModelField(title: "Model", provider: provider, task: .summary,
                                   model: $summaryProviderModel, serverModels: serverModels)
            }
```
and `.onChange(of: controller.providerStatus) { _, _ in syncProviderModels() }` on the `Form` in `detail(for:)` (so switching provider re-seeds the field), with
```swift
    private func syncProviderModels() {
        let settings = controller.settings.providerSettings
        if let provider = resolvedProvider(.summary), provider != .openRouter {
            summaryProviderModel = settings.model(for: .summary, on: provider)
        }
        if let provider = resolvedProvider(.dictation), provider != .openRouter {
            dictationProviderModel = settings.model(for: .dictation, on: provider)
        }
    }
```
`loadFromController`: add
```swift
        aiProvider = controller.settings.providerSettings.pick?.rawValue ?? "auto"
        localServerURL = controller.settings.providerSettings.localServerURL.absoluteString
        localServerKey = controller.settings.providerSettings.localServerKey ?? ""
        syncProviderModels()
```
`commitAll`: add `controller.updateLocalServerURL(localServerURL)` and `controller.updateLocalServerKey(localServerKey)` (the picker and model fields commit on change). The `credentialsSection` footer caption becomes: "Stored in your macOS Keychain and never logged. ElevenLabs powers cloud transcription; OpenRouter is one of the AI providers above."

- [ ] **Step 4: `SettingsDictationSection`**

Add the three properties after `availableModels`:
```swift
    /// The provider dictation polish resolves to; `.openRouter` renders the
    /// catalog picker below, anything else a `ProviderModelField`.
    let provider: AIProvider
    @Binding var providerModel: String
    let serverModels: [String]
```
Replace the `Picker("Polish model", …)` + its `.onChange` with
```swift
            if provider == .openRouter {
                Picker("Polish model", selection: $dictationModel) {
                    ForEach(pickerModels, id: \.self) { model in
                        Text(modelLabel(model)).tag(model)
                    }
                }
                .onChange(of: dictationModel) { _, newValue in
                    dictation.setDictationModel(newValue)
                }
            } else {
                ProviderModelField(title: "Polish model", provider: provider, task: .dictation,
                                   model: $providerModel, serverModels: serverModels)
            }
```
Update the `Toggle`'s `.help` text: "…no OpenRouter call" → "…no AI call".

- [ ] **Step 5: Onboarding caption**

In `OnboardingView.modelStep`, after the language `VStack`, inside the outer `VStack`:
```swift
                Text(providerCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
```
with
```swift
    /// What the summaries/dictation cleanup will run on, from the live
    /// detection — so a fresh install knows it needs nothing, or what to add.
    private var providerCaption: String {
        guard let status = controller.providerStatus else { return "Checking installed AI tools…" }
        let names = status.detectedNames
        if names.isEmpty {
            return "Summaries and dictation cleanup need an AI: add an OpenRouter key in Settings, or install Ollama or Claude Code."
        }
        return "Summaries and dictation cleanup will use: \(names.joined(separator: ", ")). Change it in Settings → Accounts."
    }
```

- [ ] **Step 6: Build, install, look**

Run: `swift build --package-path app 2>&1 | tail -5 && bash app/make-app.sh release && pkill -x Kleoth; open -a Kleoth`
Then ⌘, → Accounts: the AI provider section with Automatic selected; five status rows (on this Mac: Claude Code 2.1.272 · signed in, Codex 0.153.4 · signed in, OpenRouter API key set, Local server "No server at http://localhost:11434", Apple "Apple Intelligence on" or its reason); footer "Summaries via Claude Code · Dictation via Claude Code" (auto order with no local server). Pick "Apple on-device" → footer flips to "Summaries via Claude Code (Apple on-device cannot summarize) · Dictation via Apple on-device". Meetings page → the model control is the haiku/sonnet/opus/fable picker with sonnet (default). Settings → Show Welcome Window → the model step shows the caption. Record anything in words that differs from this in the commit message.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/KleothApp/Views/SettingsAIProviderSection.swift app/Sources/KleothApp/Views/ProviderModelField.swift app/Sources/KleothApp/Views/SettingsView.swift app/Sources/KleothApp/Views/SettingsDictationSection.swift app/Sources/KleothApp/Views/OnboardingView.swift
git commit -m "Settings: AI provider section, provider-aware model pickers, onboarding caption"
```

---

### Task 13: `--provider` on `kleoth summarize`, `dictate`, `localtranscribe`

**Files:**
- Create: `Sources/KleothCore/Providers/ProviderBootstrap.swift`
- Modify: `Sources/kleoth/Kleoth.swift:166-262` (`Summarize`)
- Modify: `app/Sources/dictate/main.swift` (both polisher sites, argument parsing)
- Modify: `app/Sources/localtranscribe/main.swift:13-20, 100-107`

**Interfaces:**
- Produces: `enum ProviderBootstrap { static func select(task:, pick:, settings:, credentials:, appleClient:) async -> Result<(factory: ProviderFactory, selection: ProviderFactory.Selection), ProviderError> }`; CLI flag `--provider <openrouter|local|claude-code|codex|apple>` on all three tools.

- [ ] **Step 1: `ProviderBootstrap` (core; no unit test — it only composes tested parts)**

```swift
// Sources/KleothCore/Providers/ProviderBootstrap.swift
import Foundation

/// The CLIs' one-liner: settings + credentials (+ an optional `--provider`
/// override) → a factory and the selection for a task. The app has its own
/// cached detector in `AppConfig`; the tools build a fresh one per run.
public enum ProviderBootstrap {
    public static func select(
        task: AIProvider.Task,
        pick: AIProvider?,
        settings: Settings,
        credentials: Credentials,
        appleClient: (any ChatCompleting)? = nil
    ) async -> Result<(factory: ProviderFactory, selection: ProviderFactory.Selection), ProviderError> {
        var providerSettings = settings.providerSettings
        if let pick { providerSettings.pick = pick }
        let runner = FoundationProcessRunner()
        let transport = URLSessionTransport()
        let factory = ProviderFactory(
            settings: providerSettings, openRouterKey: credentials.openRouterKey, transport: transport,
            runner: runner, locator: .standard, appleClient: appleClient)
        let detector = ProviderDetector(probes: .standard(
            locator: .standard, runner: runner, transport: transport,
            apple: { appleClient == nil ? .unavailable(reason: "Needs macOS 26") : .available(detail: "Apple on-device") }))
        let snapshot = await detector.snapshot(settings: providerSettings, openRouterKey: credentials.openRouterKey)
        return factory.select(task: task, snapshot: snapshot).map { (factory: factory, selection: $0) }
    }
}
```

- [ ] **Step 2: `kleoth summarize --provider`**

Add the option after `--model`:
```swift
    @Option(name: .long, help: "AI provider: openrouter, local, claude-code or codex. Defaults to settings / auto-detection.")
    var provider: String?
```
Replace the body from `let credentials = …` through `let summarizer = Summarizer(client: openRouter, model: resolvedModel)` with:
```swift
        let credentials = Credentials.resolve(projectDir: currentDirectoryURL())
        let settings = Settings.load()
        var pick: AIProvider?
        if let provider {
            guard let parsed = AIProvider.parse(provider), parsed != .appleOnDevice else {
                throw fail("Unknown provider '\(provider)'. Use openrouter, local, claude-code or codex.")
            }
            pick = parsed
        }
        let bootstrap = await ProviderBootstrap.select(task: .summary, pick: pick, settings: settings, credentials: credentials)
        let factory: ProviderFactory
        let selection: ProviderFactory.Selection
        switch bootstrap {
        case let .success(made):
            (factory, selection) = (made.factory, made.selection)
        case let .failure(error):
            printError("Error: \(error.localizedDescription)")
            throw ExitCode.failure
        }
        let resolvedModel = model ?? selection.model
        let baseDir = resolveOutputDir(out)
        let store = MeetingStore(baseDir: baseDir)
        let summarizer = try factory.summarizer(for: .init(provider: selection.provider, model: resolvedModel, fellThroughFrom: nil))
        printError("Using \(selection.provider.displayName) · \(resolvedModel.isEmpty ? "default model" : resolvedModel)")
```
(`printError` writes to stderr, so `stdout` stays the summary path as before.) In `summarizeExistingMeeting` and `metadataForAudio` callers, after `metadata.model = model` add `metadata.summaryProvider = selection.provider.rawValue` — pass `selection.provider` into `summarizeExistingMeeting` as a new `provider: AIProvider` parameter.

- [ ] **Step 3: `dictate --provider`**

In `parse(_:)` add `provider: String?` to the arguments struct, parsed from `--provider <id>` like `--model`. Both polisher sites (`--text` benchmark and the live run) replace the `guard let openRouterKey … OpenRouterClient(...)` with:
```swift
            let pick = arguments.provider.flatMap(AIProvider.parse)
            let apple: (any ChatCompleting)? = AppleOnDeviceClient.availability().isAvailable ? AppleOnDeviceClient() : nil
            let bootstrap = await ProviderBootstrap.select(task: .dictation, pick: pick, settings: settings,
                                                          credentials: credentials, appleClient: apple)
            let factory: ProviderFactory
            let selection: ProviderFactory.Selection
            switch bootstrap {
            case let .success(made): (factory, selection) = (made.factory, made.selection)
            case let .failure(error): fail(error.localizedDescription)
            }
            let model = arguments.model ?? selection.model
            var polisher: DictationPolisher
            do {
                polisher = try factory.polisher(for: .init(provider: selection.provider, model: model, fellThroughFrom: nil))
            } catch {
                fail(error.localizedDescription)
            }
            polisher.reasoningOverride = reasoning     // benchmark site only
            print("provider  : \(selection.provider.displayName)")
```
(`import KleothOnDevice` at the top; `dictate` already depends on the target from Task 10.) Update the usage doc comment at the top of the file with `[--provider <id>]`.

- [ ] **Step 4: `localtranscribe --provider`**

Parse `--provider <id>` from `args` next to the `scribe` flag; replace the summarizer block (lines ~100-107) with the same `ProviderBootstrap.select(task: .summary, …)` shape; on failure print `Summary skipped: <reason>` and continue with `summarizer = nil` (transcription must never be blocked by the summary). Update the usage string.

- [ ] **Step 5: Build everything and run the live probes (this Mac has Claude Code and Codex signed in, no Ollama)**

```bash
swift build && swift test
rm -f app/.build/arm64-apple-macosx/debug/description.json
swift build --package-path app --product dictate && swift build --package-path app --product localtranscribe
app/.build/debug/dictate --text "so basically we need to um deploy the pull request tomorrow morning and also tell Anna sorry Boris about it" --provider claude-code --runs 3
app/.build/debug/dictate --text "так короче нужно задеплоить пул реквест завтра утром" --language rus --provider claude-code
app/.build/debug/dictate --text "so basically we need to deploy the pull request tomorrow" --provider apple
cp -R "$(ls -d ~/Kleoth/meeting-*/ | tail -1)" /tmp/kleoth-provider-probe
swift run kleoth summarize /tmp/kleoth-provider-probe --provider claude-code
swift run kleoth summarize /tmp/kleoth-provider-probe --provider codex
grep summary_provider /tmp/kleoth-provider-probe/meta.json
```
Expected: the three `dictate` runs print `provider  : Claude Code` / `Apple on-device`, a polished line, and a median under ~3 s for Claude Code; the RU run stays Cyrillic; both `summarize` runs write `summary.md` and `meta.json` carries `"summary_provider": "claude-code"` then `"codex"`. If Apple is unavailable on this Mac, `dictate --provider apple` must print the availability reason and exit — record it in the commit message.

- [ ] **Step 6: Commit**

```bash
git add Sources/KleothCore/Providers/ProviderBootstrap.swift Sources/kleoth/Kleoth.swift app/Sources/dictate/main.swift app/Sources/localtranscribe/main.swift
git commit -m "CLI: --provider on kleoth summarize, dictate and localtranscribe"
```

---

### Task 14: Docs, changelog, release build, human checklist

**Files:**
- Modify: `CHANGELOG.md` (`[Unreleased]`), `README.md` (new section), `CLAUDE.md` (Key decisions, Commands, State)

- [ ] **Step 1: CHANGELOG**

Under `[Unreleased]` → `### Added`:
```markdown
- **Bring your own AI.** Summaries and dictation cleanup can now run on the Claude Code or
  Codex CLI you already have signed in, on a local OpenAI-compatible server (Ollama, LM Studio),
  or on Apple's on-device model (macOS 26, dictation only) — OpenRouter is one option among five.
  A fresh install auto-detects what is available (Settings → Accounts → AI provider);
  `kleoth summarize --provider <id>` picks one on the command line.
```

- [ ] **Step 2: README**

Add a section after the transcription tiers:
```markdown
## Bring your own AI

Summaries and dictation cleanup need a language model. Kleoth uses whatever you already have,
in this order, unless you pick one in Settings → Accounts:

| Provider | What it needs | Summaries | Dictation |
|---|---|---|---|
| Local server (Ollama, LM Studio, any OpenAI-compatible URL) | the server running, default `http://localhost:11434/v1` | ✓ | ✓ |
| Claude Code | the `claude` CLI installed and signed in | ✓ | ✓ |
| Codex | the `codex` CLI installed and signed in | ✓ | — |
| OpenRouter | an API key | ✓ | ✓ |
| Apple on-device | macOS 26 with Apple Intelligence on | — | ✓ |

Nothing is sent anywhere you did not sign up for: the CLIs run as the binaries you installed,
with their own login; the local server and Apple's model never leave the machine.
```

- [ ] **Step 3: CLAUDE.md**

Key decisions, new bullet:
```markdown
- **AI providers (2026-09-16):** `ChatCompleting` is the seam under `Summarizer`/`DictationPolisher`;
  backends = OpenRouter, local OpenAI-compatible server, Claude Code CLI (`claude -p` with settings/MCP
  isolation + `--system-prompt`, prompt on stdin), Codex CLI (summaries only), Apple on-device (dictation
  only, `KleothOnDevice` target, weak-linked). `ProviderResolver` auto order: local → Claude Code → Codex →
  OpenRouter → Apple. Keys: `ai_provider`, `local_server_url`, `local_server_key`, `ai_models`; meta
  `summary_provider`, log `polish_provider` (nil = OpenRouter). Design: `docs/plans/2026-09-15-ai-providers.md`.
```
Commands: add `--provider claude-code|codex|local|openrouter` to the `dictate` and `kleoth summarize` lines. State: replace the uncommitted-work line with what is true after this plan lands.

- [ ] **Step 4: Full verification and release build**

```bash
swift build && swift test 2>&1 | tail -3
swift build --package-path app 2>&1 | grep -c warning   # expected 0
bash app/make-app.sh release && pkill -x Kleoth; open -a Kleoth
otool -L /Applications/Kleoth.app/Contents/MacOS/Kleoth | grep -E "FoundationModels|AVKit"
```
Expected: tests green (≈354 + ~60 new), zero warnings, FoundationModels listed as `(weak)`.

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md README.md CLAUDE.md
git commit -m "Docs: bring-your-own-AI providers"
```

- [ ] **Step 6: Hand the human checklist to the user (in the final message, not a file)**

1. Settings → Accounts: the provider rows read as expected for this Mac; Refresh works.
2. Record a short meeting with Automatic → summary lands; `meta.json` has `summary_provider: claude-code`.
3. fn+shift a 30-word dictation into TextEdit → polished; the day file row has `polish_provider`.
4. Pick Apple on-device → the same dictation → `polish_provider: apple`; a summary still runs on Claude Code (footer says why).
5. Sign out of Claude Code (`claude /logout`) → Settings row flips to "Not signed in" within a minute; a summary shows the sign-in error card; sign back in.
6. With Ollama installed (`brew install ollama && ollama pull llama3.2 && ollama serve`): the Local server row shows the model count, Automatic switches to it, a summary runs on it.
7. `kleoth summarize <dir> --provider codex` from a terminal.

## Self-review

- **Spec coverage:** §2 behavior — picker/status/footer (T12), model pickers per provider (T12), auto order + fall-through (T4/T8), no-provider copy (T2/T11), CLI flag (T13), zero cost (T1/T6/T7), onboarding caption (T12). §3 contract — every type named there exists in T1–T8 and T10, with these deliberate renames: `Resolution` is an enum with a third `unavailable` case (an explicitly picked, unusable provider must surface as an error, not fall through silently), `ProviderAvailability.available` carries the local server's model ids, and `ProviderBootstrap` is the CLIs' composition helper the spec did not name. §4 storage (T3/T9/T11). §5 wiring (T11/T12/T13). §6 errors (T2 copy, T8 mapping, T11 surfaces). §7 tests (each task) and live probes (T13 step 5).
- **Placeholders:** none; every step carries code or an exact command.
- **Type consistency:** `ChatCompletion.usage: ChatUsage?` is read as `.usage?.cost` by the polisher/summarizer (unchanged member names); `ProviderFactory.Selection(provider:model:fellThroughFrom:)` is used identically in T8, T11, T13; `ProviderAvailability.available(detail:models:)` pattern-matched with `case let .available(_, models)` in T8/T12 and constructed with one argument elsewhere (the default); `ProcessRunner.run(executable:arguments:stdin:environment:timeout:)` is the same in T5–T8.
