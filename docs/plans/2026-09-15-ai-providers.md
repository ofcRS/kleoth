# AI providers — bring your own model (design, 2026-09-15)

Kleoth's two language-model calls (meeting summaries, dictation polish) currently require an
OpenRouter key. This design lets them run on whatever the user already has: an installed
Claude Code or Codex CLI signed into their own subscription, a local OpenAI-compatible server
(Ollama, LM Studio, anything at a URL), or Apple's on-device model on macOS 26. OpenRouter stays
as one option among five. Approved by the user on 2026-09-15 with: all four new backends in v1,
one provider setting with per-task models, auto-detection on a fresh install, no policy note.

## 1. Facts this design rests on (measured 2026-09-15 on this Mac)

| Backend | Structured JSON | Trivial call | Overhead | Fit |
|---|---|---|---|---|
| Claude Code 2.1.272, `claude -p --json-schema` | `structured_output` | 1.6 s (haiku) with isolation flags; 4.5–7 s without | 7k cached tokens with isolation; 154k without (the user's MCP servers + plugins) | summaries + dictation |
| Codex 0.153.4, `codex exec --json --output-schema` | `agent_message` text | 12 s | 13.7k input tokens | summaries only |
| Ollama / LM Studio (`/v1/chat/completions`) | `response_format` json_schema, json_object fallback | not installed here | — | summaries + dictation |
| Apple Foundation Models (macOS 26) | `@Generable` | fast | 4096-token context, fixed | dictation only |

- Isolation flags that cut Claude Code's overhead: `--setting-sources "" --strict-mcp-config
  --mcp-config '{"mcpServers":{}}' --tools "" --no-session-persistence`. `--bare` cannot be used:
  it skips the keychain read and reports "Not logged in".
- Sign-in state: `claude auth status` prints JSON with `loggedIn`; `codex login status` prints
  "Logged in using ChatGPT" (exit 0) and `~/.codex/auth.json` exists.
- `gpt-5-mini` is refused on a ChatGPT-account Codex; the account default model works. Codex model
  is therefore optional free text, default = no `-m`.
- Policy: Anthropic's legal page forbids reusing subscription OAuth tokens in other products and
  routing requests through Pro/Max credentials on users' behalf, and permits an end user signing
  into the unmodified Claude Code binary with their own subscription. Kleoth spawns the user's own
  installed binary and never reads, stores or passes a token. The June 2026 plan to meter `claude
  -p` from a separate credit pool was cancelled on 2026-06-16.
- No existing Swift package covers CLI harnesses; the HTTP unifiers (llmkit-swift, aikitswift)
  duplicate what `OpenRouterClient` already is. No new dependency.

## 2. Behavior

- **Settings → Accounts** opens with an **AI provider** section: a picker — Automatic (default),
  OpenRouter, Local server, Claude Code, Codex, Apple on-device — each row subtitled with live
  status ("Ollama at localhost:11434 · 5 models", "Claude Code 2.1.272 · signed in", "Not
  installed", "Apple Intelligence is off"). Local server shows a URL field (default
  `http://localhost:11434/v1`) and an optional key field. A footer states what is in use per
  task: "Summaries via Claude Code · Dictation via Apple on-device".
- **Model pickers stay where they are** (Meetings page: summary model; Dictation page: polish
  model) and list the resolved provider's models: OpenRouter's catalog as today; the local
  server's `GET /v1/models`; Claude Code's aliases `haiku`, `sonnet`, `opus`, `fable`; Codex's
  free-text field (empty = account default); Apple's single model (picker hidden).
- **Automatic** picks, per task, the first available in this order: local server → Claude Code →
  Codex → OpenRouter → Apple on-device. An explicit pick that cannot do a task (Codex for
  dictation, Apple for summaries) falls through the same order for that task, and the footer says
  so ("Summaries via Claude Code — Apple on-device cannot summarize").
- **No provider available** = today's no-key behavior: summaries skipped, dictation pasted as
  heard. The popover line "Summaries need an OpenRouter key" becomes "No AI provider available —
  open Settings → Accounts". Onboarding's keys step gains one caption naming what was detected.
- **CLI:** `kleoth summarize --provider <id>`; `localtranscribe` and `dictate` gain the same flag.
  Without it they resolve exactly like the app.
- Costs recorded in `meta.json` / the dictation log are **0** for every backend except
  OpenRouter (subscription and local usage is not billed per call).

## 3. Interface contract (KleothCore unless noted)

```swift
public struct ChatCompletion: Sendable { content: String; usage: ChatUsage?; finishReason: String? }
public struct ChatUsage: Sendable { promptTokens: Int?; completionTokens: Int?; cost: Double? }  // = today's OpenRouterUsage, renamed

public protocol ChatCompleting: Sendable {
    func complete(messages: [ChatMessage], model: String, responseFormat: OpenRouterResponseFormat,
                  maxTokens: Int, temperature: Double?, reasoning: OpenRouterReasoning?) async throws -> ChatCompletion
}
```
`Summarizer.client` and `DictationPolisher.client` become `any ChatCompleting`. Their bodies do
not change. `OpenRouterResponseFormat` / `OpenRouterReasoning` keep their names (no churn);
adapters ignore `reasoning` when the backend has no equivalent.

```swift
public enum AIProvider: String, Codable, CaseIterable, Sendable {
    case openRouter = "openrouter", localServer = "local", claudeCode = "claude-code", codex = "codex", appleOnDevice = "apple"
    public enum Task { case summary, dictation }
    public func supports(_ task: Task) -> Bool    // codex: summary only; apple: dictation only; others both
    public static let autoOrder: [AIProvider] = [.localServer, .claudeCode, .codex, .openRouter, .appleOnDevice]
    public var displayName: String
    public func defaultModel(for task: Task) -> String   // openrouter: ModelCatalog.defaultModel / DictationDefaults.polishModel;
                                                         // claude-code: "sonnet" / "haiku"; local: "" (first listed); codex: ""; apple: "apple-on-device"
}

public enum ProviderAvailability: Sendable, Equatable {
    case available(detail: String)        // "Claude Code 2.1.272 · signed in"
    case unavailable(reason: String)      // "Not installed", "Not signed in", "No server at …", "Apple Intelligence is off"
}
public actor ProviderDetector {           // results cached 60 s; `refresh()` drops the cache
    public func availability(of: AIProvider) async -> ProviderAvailability
    public func snapshot() async -> [AIProvider: ProviderAvailability]
}
public struct ProviderResolver: Sendable { // pure given a snapshot — tested
    public static func resolve(task: AIProvider.Task, pick: AIProvider?, snapshot: [AIProvider: ProviderAvailability]) -> Resolution?
    public struct Resolution: Equatable { provider: AIProvider; fellThroughFrom: AIProvider? }
}
public struct ProviderSettings: Sendable, Equatable {   // parsed from config/Keychain strings — tested
    public var pick: AIProvider?                        // nil = Automatic
    public var localServerURL: URL                      // default http://localhost:11434/v1
    public var localServerKey: String?
    public var models: [AIProvider: [AIProvider.Task: String]]   // absent → provider.defaultModel(for:)
}
```
Clients:
- `OpenAICompatibleClient(baseURL:apiKey:sendsOpenRouterProviderKey:)` — today's
  `OpenRouterClient` generalized; `OpenRouterClient` stays as a convenience init (openrouter.ai
  URL + `provider.require_parameters`). Local servers get no `provider` key. The 400/404 relaxed
  retry (schema → json_object, drop temperature/reasoning) stays, it is what makes Ollama/LM Studio
  variance survivable. A 404 whose body contains "not found" and "pull" is rewritten to
  "Model '<m>' is not on the local server — run `ollama pull <m>`".
- `ClaudeCodeClient(runner:executable:)` — args: `-p --output-format json --tools ""
  --no-session-persistence --setting-sources "" --strict-mcp-config --mcp-config
  {"mcpServers":{}} --model <m> --system-prompt <system> --json-schema <schema>` (json-schema only
  for `.jsonSchema`; `.jsonObject` appends "Return only a JSON object." to the prompt). The first
  `system` message → `--system-prompt`; every other turn is flattened into the stdin prompt as
  `User:` / `Assistant:` blocks (the Summarizer's repair retry is the only multi-turn caller).
  Output: `structured_output` re-serialized, else `result`; `is_error` → `ProviderError.backend(
  message)` with the `result` text ("Not logged in · Please run /login" → "Claude Code is not
  signed in. Open a terminal, run `claude`, and sign in."). `stop_reason` maps to `finishReason`
  (`max_tokens` → "length"). Usage tokens copied, cost nil.
- `CodexClient(runner:executable:)` — args: `exec --json --skip-git-repo-check -s read-only
  --ephemeral --color never -C <tmp dir> [-m <m>] --output-schema <tmp file> -`; system + turns
  flattened to stdin (Codex has no system-prompt flag; the system text leads the prompt). Output:
  JSONL, last `item.completed` with `item.type == "agent_message"` → content; `turn.failed` /
  `error` → `ProviderError.backend`. Temp schema file deleted in a `defer`.
- `ProcessRunner` protocol: `run(executable: URL, arguments: [String], stdin: Data?, environment:
  [String: String], timeout: TimeInterval) async throws -> ProcessResult(stdout, stderr, status)`.
  `FoundationProcessRunner` (Foundation.Process, pipes drained on background readers, cancellation
  → `terminate()` then `kill` after 2 s); `MockProcessRunner` in tests records arguments and
  returns fixtures. Environment = a minimal `HOME`, `PATH` (the locator's directories), `TMPDIR`,
  `LANG`; nothing from Kleoth's own environment.
- `ToolLocator.find("claude")` checks, in order: `~/.local/bin`, `/opt/homebrew/bin`,
  `/usr/local/bin`, `~/.local/share/mise/shims`, `~/.codex/bin`, then each `$PATH` entry. Returns
  the first executable regular file. Version = `<tool> --version` first line, cached with detection.
- **App package**, new target `KleothOnDevice` (macOS 26 API, weak-linked so the 14.4 floor
  holds): `AppleOnDeviceClient: ChatCompleting`. `LanguageModelSession(instructions:)` with the
  system text; `respond(to:generating: DictationPolishPayload.self)` where the `@Generable` struct
  mirrors `DictationPrompt.schemaJSON`; response re-encoded as JSON for the polisher's decoder.
  Any other schema name → `ProviderError.unsupported`. Inputs over 3,500 estimated tokens
  (chars ÷ 3.5) and `GenerationError.exceededContextWindowSize` → `ProviderError.inputTooLong`,
  which the polisher already turns into "pasted as heard". Availability =
  `SystemLanguageModel.default.availability` (`.deviceNotEligible`, `.appleIntelligenceNotEnabled`,
  `.modelNotReady` → readable reasons).
- `ProviderError: LocalizedError` — `.notInstalled(tool)`, `.notSignedIn(tool)`,
  `.unreachable(url)`, `.modelMissing(model, hint)`, `.inputTooLong`, `.unsupported(task)`,
  `.backend(message)`, `.timedOut`.

## 4. Storage (snake_case, acronym-free; Keychain in the app, config.json for the CLI)

| Key | Values | Default |
|---|---|---|
| `ai_provider` | `auto` / `openrouter` / `local` / `claude-code` / `codex` / `apple` | `auto` |
| `local_server_url` | URL string | `http://localhost:11434/v1` |
| `local_server_key` | string | empty |
| `ai_models` | JSON `{"claude-code":{"summary":"sonnet","dictation":"haiku"}, …}` | empty (defaults apply) |

`default_model` and `dictation_model` keep meaning OpenRouter's models, so nothing migrates.
`meta.json` gains optional `summary_provider`; dictation rows gain optional `polish_provider`;
nil = OpenRouter (old files read unchanged). `Keychain.Account` gains the four accounts;
`Settings` gains `providerSettings: ProviderSettings`.

## 5. App wiring

- `AppConfig.makeSummarizer() async -> (Summarizer, AIProvider)?` and `makePolisher() async ->
  (DictationPolisher, AIProvider)?` replace the six `guard openRouterKey` sites
  (`RecordingController` ×4, `DictationController`, plus `kleoth`/`localtranscribe`/`dictate`
  through a shared `ProviderFactory` in KleothCore that takes credentials + settings + a
  snapshot). Nil = no provider available, same branches as today.
- The dictation polish fallback model (`DictationDefaults.fallbackPolishModel`) applies only on
  OpenRouter; other providers pass `fallbackModel: nil`.
- Settings: `SettingsView` gains `@State` for the four keys; `commitAll()` flushes them like the
  rest. The provider section polls `ProviderDetector.snapshot()` on appear and every 5 s while
  the page is visible (the mic picker's idiom). Model pickers call
  `ModelCatalog.fetch` (OpenRouter) or `LocalModelList.fetch(url:)` (`GET /v1/models`) or use the
  static alias list.
- Popover: `MenuView` reads `RecordingController.aiProviderStatus` (recomputed on settings
  change and on `didBecomeActive`) for the no-provider line.
- Onboarding keys step: caption "Detected: Claude Code, Ollama" / "Nothing detected — add an
  OpenRouter key or install Ollama". No new step.

## 6. Error matrix

| Situation | Where it shows | Message |
|---|---|---|
| Picked tool not installed | Settings row, meeting error card, pill warning | "Claude Code is not installed." |
| Tool not signed in | same | "Claude Code is not signed in. Open a terminal, run `claude`, and sign in." |
| Local server down | same | "No server at http://localhost:11434 — is Ollama running?" |
| Model missing on local server | meeting card / pill | "Model 'x' is not on the local server — run `ollama pull x`." |
| Apple Intelligence off | Settings row | "Apple Intelligence is off (System Settings → Apple Intelligence & Siri)." |
| Dictation too long for Apple | pill warning | existing "pasted the raw transcript" path, reason "Too long for the on-device model." |
| CLI hangs | meeting card / pill | "Claude Code did not answer within 10 minutes." / dictation: existing 30 s budget → raw |
| Codex refuses model | meeting card | backend message verbatim ("The 'x' model is not supported when using Codex with a ChatGPT account.") |

## 7. Tests

Pure (KleothCoreTests): `ProviderResolver` order + task fall-through + explicit pick;
`ProviderSettings` parsing (bad URL → default, unknown provider → auto, `ai_models` round-trip);
`ClaudeCodeClient` argument list and message flattening, output parsing against fixtures captured
today (success with `structured_output`, `is_error` not-logged-in, `max_tokens` stop);
`CodexClient` arguments, JSONL parsing (success, `turn.failed`, model-refused error);
`OpenAICompatibleClient` body has no `provider` key for a local URL and the Ollama "pull" 404
rewrite; `ToolLocator` search order with a temp directory tree; `ProviderError` messages.
Live (by the agent, on this Mac): `dictate 4 --provider claude-code`, `dictate --text "…"
--provider claude-code --runs 3` (latency), `kleoth summarize <copy of a meeting> --provider
claude-code` and `--provider codex`, Settings by eye after install.
Needs a human with Ollama: the local path end to end (unit-tested against the recorded shape only).

## 8. Out of scope (v1)

Gemini CLI (not installed here; one adapter file later), per-app provider overrides, streaming,
transcription via any of these (WhisperKit/Scribe unchanged), a provider-specific system prompt.

## 9. Deviations (2026-09-16)

What shipped differs from the design above in these ways — all deliberate, none re-litigated:

1. **Detector cache TTL is 600 s, not 60.** §3 said one minute; a probe pass shells out to two
   CLIs and hits the local server, which is far too expensive on a dictation hot path. Every
   provider-setting write calls `refresh()`, so the user never looks at a stale cache after an edit.
2. **`ProviderDetector.availability(of:)` was not implemented.** Only `snapshot(settings:openRouterKey:)`
   exists; every caller wants all five providers at once (Settings footer, popover, both factories),
   and a per-provider entry point would have been a second, separately-cached path.
3. **§5's MenuView resting hint is not wired.** The popover does not carry a "no AI provider" line at
   rest; the status line shows the reason after an attempt instead (and, since this wave, an explicit
   pick that cannot be built pins "Summary skipped: …" to the meeting — see 7).
4. **`ProviderResolver.Resolution` is an enum with an `unavailable` case**, not an optional
   selection: an explicitly picked provider that is down must produce its OWN typed error
   (`unreachable(url:)`, `notSignedIn(tool:)`), which a `nil` cannot carry.
5. **`ProviderAvailability.available` carries the local server's model ids** (`available(detail:models:)`).
   The detector already has the `/v1/models` list, and `ProviderFactory.select` needs it to default a
   local server with no stored model to its first one.
6. **`Settings.effectiveProviderSettings` seeds OpenRouter's models from the legacy keys**
   (`default_model` → summary, `dictation_model` → dictation), so an upgrading user keeps the exact
   slugs they had without a migration write.
7. **One-time `ai_provider = openrouter` seed for existing OpenRouter installs.** With no stored pick
   the Automatic order puts local/Claude Code/Codex ahead of OpenRouter, so a user who already had a
   working key would silently upgrade onto a different backend. `AppConfig.mergeSettingsFromKeychain`
   seeds the pick once when there is a non-empty OpenRouter key AND onboarding is completed; fresh
   installs stay Automatic.
8. **Claude Code dictation polish measured ~8–10 s per cleanup on this Mac** (vs ~1 s on
   `google/gemini-3.5-flash-lite` through OpenRouter). It works and is listed for dictation, but the
   README calls it slow and it is why 7 exists.
