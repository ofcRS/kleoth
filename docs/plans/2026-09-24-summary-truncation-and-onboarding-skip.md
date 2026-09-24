# Cut-off summaries and the consent dead end — design

_2026-09-24. Two high-severity bugs from a June 2026 code review, re-verified against today's working
tree (`feat/dictation-retry`). Commit `122005b` (2026-06-08) already fixed the headline of each; this
doc designs what survives. Builds on `2026-09-15-ai-providers.md` (the `ChatCompleting` seam)._

## 1 The ask

1. **Summaries cut off without anyone noticing.** The summarizer asks for at most 8192 output tokens,
   and reasoning-capable models spend part of that thinking. Reported: an empty answer failed the
   summary before the retry could run, and an answer cut off after `tldr` was shown as a finished
   summary with no overview and no action items. Summaries now also run on a local server, Claude
   Code and Codex; the fix must cover all of them, and a cut-off summary must never look complete.
2. **"Skip setup" dead end.** Skip jumps from the welcome step to the finish step, past the only
   onboarding step that records the recording-consent acknowledgement. "Start your first recording"
   then calls `start()`, which refuses without consent and says so only in the popover — after the
   window has closed.

Also asked: check every other way a recording starts; say whether "a failed re-summarize leaves a
stale summary" belongs here; keep 2 small, because onboarding will be redesigned.

## 2 Root cause

### 2.1 Summaries — already fixed (verified today)

- `finish_reason` is decoded (`OpenAICompatibleClient.swift:45-50`). A choice with empty or null
  content comes back as an empty completion; `noContent` is thrown only when there are no choices
  (`:178-187`).
- `Summarizer` treats `"length"` as a failure even when the text decodes, re-asks with the original
  messages at twice the budget, and throws rather than accept a second cut-off
  (`Summarizer.swift:144-186`; tests `SummaryDecodeTests.swift:271-334`).
- Claude Code maps `stop_reason: "max_tokens"` to `"length"` (`ClaudeCodeClient.swift:109`).
- The `json_object` fallback is no longer the everyday path: the default `z-ai/glm-5.3-flash` honours
  the strict schema (`ModelCatalog.swift:21-33`). The fallback (`OpenAICompatibleClient.swift:101-115`)
  still runs for models whose endpoints can't honour it under `require_parameters`.

### 2.2 Summaries — what survives

1. **A cut-off is recognised only by its finish reason.** Codex reports `"stop"` for every answer
   (`CodexClient.swift:112-115`), Claude Code for everything but `max_tokens`
   (`ClaudeCodeClient.swift:109`), and local servers vary. A cut-off JSON with any other finish reason
   takes the *malformed* branch: the partial text is replayed as an assistant turn at the same 8192
   cap (`Summarizer.swift:156-168`) — more input, the same room — and for the CLIs the replay is
   flattened into one longer prompt (`ChatCompleting.swift:73-84`). It ends as `invalidJSON`, so it is
   never shown, but it is misfiled and the retry is built to fail. Neither CLI receives an output cap
   (`ClaudeCodeClient.swift:52-61`, `CodexClient.swift:58-67`), so "twice the budget" does nothing there.
2. **An empty answer that isn't `"length"` is replayed as an empty assistant turn**
   (`Summarizer.swift:161-167`). Anthropic's API (and some strict OpenAI-compatible upstreams) reject a
   non-final empty message with HTTP 400, so the summary fails with an unrelated "non-empty content"
   error.
3. **A complete JSON object with parts missing is accepted.** `MeetingSummary` requires only `tldr`
   (`MeetingSummary.swift:44-57`, lenient on purpose so old files load), the summarizer accepts any
   decodable answer not marked `"length"` (`Summarizer.swift:147-150`), and the detail view drops empty
   sections without a word (`MeetingSummaryView.swift:7-8, 36-54`). So `{"tldr": …, "summary": …}` —
   key drift on the `json_object` path, a local server ignoring `response_format`, or Claude Code
   answering in `result` text without `structured_output` (passed on as is,
   `ClaudeCodeClient.swift:102-108`) — shows as a finished summary with no overview and no action
   items. The reported gutted summary survives through a missing key rather than a cut-off.
4. **A failed summary looks pending and can't be retried.** After a (re)transcription the summary
   error reaches only the popover's status line (`RecordingController.swift:1104-1105, 1285-1286,
   1444-1445`); `meetingErrors` is not set, so History shows no "Failed" chip and the detail pane shows
   the neutral "No summary yet" (`MeetingDetailView.swift:164-166`). The only in-app retry besides a
   paid cloud re-transcription is "summarize latest" (`kleoth://summarize-latest` or its intent,
   `RecordingController.swift:320-407`). And `meta.json` still names the provider and model that
   failed: callers set them before the run (`RecordingController.swift:1068-1077, 1238-1242,
   1418-1421`; `Kleoth.swift:237-238`), the pipeline saves them regardless (`MeetingPipeline.swift:81-109`),
   and the header shows the model as a chip (`MeetingDetailView.swift:154-156`) — though
   `summaryProvider` is documented as the provider that produced `summary.json`
   (`MeetingMetadata.swift:22-25`).
5. **A local server can cut the input instead.** Ollama's OpenAI-compatible endpoint can't raise the
   context per request; its default is 4k tokens below 24 GiB of VRAM (Ollama's context-length docs —
   likely most 16–32 GB Macs), and a longer prompt reportedly loses its oldest tokens without an error.
   The answer is complete JSON about the end of the meeting; nothing in it shows the loss (§9 Q4).

### 2.3 Stale summary after a failed re-summarize

Closed for every reachable flow. Re-transcribing into the other tier first moves the root transcript
*and* summary into `variants/<tier>/` (`MeetingStore.swift:181-212`, called at
`RecordingController.swift:1222-1236, 1370-1384`), so a failed summary leaves no summary at the root.
Re-transcribing into the same tier is not offered (`MeetingDetailView.swift:391-411`); the CLI
transcribes into new folders; summarizing in place leaves the transcript alone, so a kept summary still
matches it. What remains is latent: `MeetingPipeline.run` never removes a root summary
(`MeetingPipeline.swift:53-66`; `MeetingStore.swift:53-56, 74-79`). Not in this fix (§7).

### 2.4 Consent

Already fixed: Skip still jumps to the finish step (`OnboardingView.swift:434-437`), but "Start your
first recording" checks `consentAcknowledged` and routes to the permissions step when it is missing
(`:467-476`).

What survives is the silent refusal: `start()` refuses by writing `statusMessage`
(`RecordingController.swift:609-612`), which only the popover shows. Every way a meeting recording
starts:

| Path | Where | Without consent today |
|---|---|---|
| Popover Start | `MenuView.swift:162-183` | disabled; consent card above it (`:36-39`) |
| Onboarding "Start your first recording" | `OnboardingView.swift:467-480` | goes to the permissions step |
| Global record hotkey | `AppWiring.swift:62-64` → `handle(.toggle)` | **nothing visible** |
| `kleoth://record`, `kleoth://toggle` | `AppWiring.swift:133-141` → `handle(_:)` | **nothing visible** |
| Start Recording intent | `KleothIntents.swift:26-31` | dialog "Acknowledge the recording consent notice first." — nothing to click |
| Pill | `PillCoordinator.swift:198-200` | no meeting start: its Record is a screen recording, which has no consent gate |

Consent can be given only in the onboarding permissions step (`OnboardingView.swift:230-243`) and in
the popover card (`ConsentView.swift:23-25`).

## 3 Behaviour

### 3.1 When an answer becomes a summary (every provider)

All of:

- **Not cut off:** the finish reason isn't `"length"`, and the text — after fence stripping — isn't a
  JSON object that stops before it closes (starts with `{`, ends inside a string, object or array).
- **Decodes** as `MeetingSummary`.
- **Complete:** `tldr` is non-blank, and `overview`, `action_items` and `per_speaker_highlights` are
  present under a spelling the decoder reads (`action_items` or `actionItems`). Lists may be empty and
  `overview` may be blank (a ten-second recording); `title` stays optional.

The first request is byte-identical to today's.

### 3.2 The one retry

| First answer | Retry |
|---|---|
| cut off with no text (the budget went on reasoning) | fresh request, 2 × budget, compact instruction, `reasoning: low` |
| cut off with text | fresh request, 2 × budget, compact instruction |
| empty, not cut off | fresh request, same budget |
| JSON object with parts missing | the answer, then "Your previous answer is missing: overview, action_items. Return the complete JSON object with every key — no prose, no markdown fences." |
| not JSON | the answer, then today's "not valid JSON" nudge |

*Fresh* = the original system and user messages; bad text is never replayed. The *compact
instruction* is one sentence appended to the user message: "Your previous answer was cut off before
the JSON was complete. Answer again, more compactly — a shorter overview and fewer highlights — in the
same language and the same JSON shape." `reasoning: low` reaches OpenRouter and local servers (the
CLIs ignore it); an endpoint that can't take it gets the client's existing relaxed retry, which drops
it together with the strict schema.

After the retry anything short of a complete answer throws, and nothing is written:

| Still | Error | Message |
|---|---|---|
| cut off | `.truncated` | "The summary was cut off: the model ran out of output room before finishing (reasoning models spend part of it thinking). Try again, or use another model." |
| parts missing | `.incomplete(missing:)` | "The summary came back incomplete (no overview, action items). Try again, or use another model." |
| empty | `.invalidJSON("")` | "The model returned an empty answer." |
| not JSON | `.invalidJSON(snippet)` | unchanged |

A retry after a cut-off that the provider refuses with HTTP 400 or 404 (the doubled budget exceeds
that model's limit) also throws `.truncated`.

### 3.3 What the user sees

- **No partial summary, ever.** A failed summary writes nothing: the transcript is saved as always,
  and a summary already on disk stays (summarizing in place).
- **Detail pane:** the "Last attempt failed" card reads "Summary failed: <message>". The header shows
  "No summary yet" and a small **Summarize** button — on every transcribed meeting without a summary,
  failed or never tried. It is disabled while the meeting is busy and when no provider resolves (the
  tooltip is then the provider error, otherwise "Summarize with <provider>"). While it runs, the
  progress banner reads "Summarizing…".
- **History row:** the "Failed" chip, with the message as its tooltip.
- **Popover:** `Transcribed "<title>" — summary failed: <message>` (the three pipeline branches keep
  their prefixes). "Summary skipped: …" stays for an explicitly picked provider that can't be built.
- **meta.json:** `model` and `summary_provider` only when this run wrote a summary, so the header's
  model chip goes with it.
- **After a relaunch** the card is gone (in memory, like every meeting error); "No summary yet" and
  Summarize stay.
- **Summarize** runs the summary alone on the current provider, outside the pipeline queue like
  today's summarize-latest (which now calls it for the newest meeting only). Success saves
  `summary.json` / `summary.md`, adopts the model's title for a placeholder title and clears the card;
  failure pins the new reason.
- **CLI:** `kleoth summarize <dir>` exits non-zero with the message and writes nothing;
  `kleoth summarize <audio>` still prints "Summary step failed (transcript was saved): <message>". New
  `--max-output-tokens <n>` (default 8192; a cut-off retry doubles it).

### 3.4 Consent

- Popover and onboarding: unchanged.
- The hotkey, `kleoth://record|toggle` and the Start intent without consent: `start()` still refuses,
  and the refusal now also brings a small **Before you record** window forward — the popover's consent
  text, **I understand — start recording** and **Not now**. The first acknowledges, starts, and closes
  the window once `isRecording` is true; if the start fails, the window stays and shows the status
  message. The intent's dialog is unchanged.
- Screen recording: unchanged, no consent gate (§9 Q6).
- Launch argument `-KleothSimulateFirstRun YES`, read from the argument domain only: for that launch
  consent and onboarding read as not done, so first-run flows can be exercised on a Mac that consented
  long ago. The flag persists nothing.

### 3.5 What the onboarding redesign inherits

1. The consent guard lives inside `start()`; callers never duplicate it. A new start path — track 2's
   pill meeting button, a "you're in a call" prompt — calls `start()` and gets the visible refusal free.
2. Every refusal shows where the user acted: the popover card there, the consent window anywhere else.
3. A window that starts a recording closes only once it runs. Today's onboarding Start dismisses before
   `start()` returns (`OnboardingView.swift:477-479`), so a non-consent failure there is still invisible.
4. Skip never leads to a primary action that can't complete.
5. `-KleothSimulateFirstRun` keeps working.

## 4 Contract

### 4.1 KleothCore

`Summarization/Summarizer.swift`:

```swift
public enum SummarizerError: Error, Sendable {
    case transcriptTooLong(approxTokens: Int)   // unchanged
    case invalidJSON(snippet: String)           // unchanged; "" reads "The model returned an empty answer."
    case truncated                              // new
    case incomplete(missing: [String])          // new; keys as the prompt spells them
}

public struct Summarizer: Sendable {
    public static let defaultMaxOutputTokens = 8192
    public var maxOutputTokens: Int             // was a private static
    public init(client: any ChatCompleting, model: String = ModelCatalog.defaultModel,
                maxOutputTokens: Int = Summarizer.defaultMaxOutputTokens)

    static func isTruncated(_ finishReason: String?) -> Bool      // unchanged: DictationPolisher.swift:192 uses it

    // internal, tested directly
    enum Assessment { case complete(MeetingSummary), cutOff(hadText: Bool), empty,
                      incomplete(missing: [String]), malformed }
    static func assess(_ completion: ChatCompletion) -> Assessment
    static func isUnterminatedJSONObject(_ text: String) -> Bool
    static let compactRetryInstruction: String
}
```

The retry passes `reasoning: .low` only after `.cutOff(hadText: false)`; the `OpenRouterReasoning` doc
comment ("`Summarizer` never does", `OpenRouterClient.swift:69-70`) is updated to say so.

`Pipeline/MeetingPipeline.swift`: when the run writes no summary, the saved `meta.json` drops `model`
and `summaryProvider`. Signature and return value unchanged.

No new stored keys. `ChatCompleting`, `ChatCompletion` and every adapter are unchanged.

### 4.2 CLI

`kleoth summarize … --max-output-tokens <n>` sets `Summarizer.maxOutputTokens`.

### 4.3 KleothApp

```swift
// RecordingController
@Published public private(set) var consentRequest: Int   // bumped by start() when it refuses for consent
public func summarize(_ meeting: RecentMeeting) async    // summarizeLatestMeeting() calls it
@discardableResult public func summarizeLatestMeeting() async -> String   // the outcome = the intent's dialog
```

- Summarize latest targets **the newest meeting only** (the user's decision, 2026-09-24): a
  Stop → Summarize Latest Shortcut must never re-summarize an older meeting (a paid call that
  replaces its summary). Recording in progress or untranscribed → "The newest meeting isn't
  transcribed yet."; no meetings → "No meeting to summarize yet."; processing → returns "The newest
  meeting is still being processed." without touching the status line (it shows the run's progress).

- `KleothApp.swift`: a `Window("Before you record", id: "kleoth-consent")` scene; `KleothMenuBarLabel`
  takes `consentRequest` and opens that window on change — the `historyRequest` pattern
  (`KleothApp.swift:107-111`).
- `ConsentView(startsRecording: Bool = false)`: `true` is the window variant (button copy, start,
  close once recording, `AppActivation.windowOpened()` / `windowClosed()`).
- Meeting-error copy: "Summary failed: <message>" (summarize-latest said "Summarize failed:").
- `-KleothSimulateFirstRun`: read in `RecordingController.init` from
  `UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)`.

### 4.4 Shared with the sibling tracks

| File / contract | Sibling track | This fix |
|---|---|---|
| `Summarizer.isTruncated`, `Summarizer.languageName` | 1 context-aware dictation (the polisher calls both) | unchanged |
| `OpenRouterClient.swift` | 1 | doc comment only |
| `RecordingController.swift` | 2 meetings in the pill | `start()` refusal branch, `consentRequest`, the `init` flag, `summarize(_:)`, three pipeline branches |
| `KleothApp.swift`, `ConsentView.swift` | 2 | new scene, label input, view mode |
| `start()` semantics | 2 | a consent refusal opens the window by itself — new start paths must not add their own check |
| `meetingErrors` | 2 (if the pill shows meeting errors) | now also carries "Summary failed: …" |
| `MeetingDetailView.swift` header row | 3 meeting illustrations | Summarize button |
| `MeetingPipeline.run`, `meta.json` | 3 | `model` / `summary_provider` only with a summary; anything generated from the summary must not run when it failed |

## 5 Error matrix

| Case | User sees | Written |
|---|---|---|
| Complete first time, or complete after the retry | the summary | summary |
| Cut off twice (either signal), or the bigger retry refused (400/404) | card "Summary failed: The summary was cut off…", Failed chip, "No summary yet" + Summarize | transcript only |
| Parts missing twice | "…came back incomplete (no overview)." | transcript only |
| Empty twice | "…The model returned an empty answer." | transcript only |
| Not JSON twice | "…did not return a complete summary. Got: …" (unchanged) | transcript only |
| Other client or transport error | "Summary failed: <error>" | transcript only |
| No provider resolvable | pipeline unchanged; Summarize disabled with the reason | — |
| Summarize in place fails | the card updates | nothing; an existing summary stays |
| Start without consent — popover, onboarding | unchanged | — |
| Start without consent — hotkey, `kleoth://`, intent | Before you record window (+ the intent's dialog) | — |
| Consent window, then the start fails | the window stays, showing the status | consent acknowledged |

## 6 Tests

Core, swift-testing in `Tests/KleothCoreTests`; each fails on today's code unless marked *lock*.

`SummaryCompletenessTests.swift` (new, `MockChatClient`):

- `cutOffJSONWithoutLengthIsReaskedFresh` — `{"tldr":"a","overview":"b` + `"stop"`, then a complete
  answer: returned; the second call has 2 messages ending in the compact instruction and
  `maxTokens == 16384`. *Today: 4 messages, 8192.*
- `cutOffWithNoTextRetriesWithLowReasoning` — `""` + `"length"`: second call `reasoning == .low`,
  first `nil`. *Today: nil.*
- `cutOffWithTextLeavesReasoningUnset` — partial + `"length"`: `reasoning == nil`, instruction present.
  *Today: no instruction.*
- `emptyAnswerIsNotReplayed` — `""` + `"stop"`: the second call has 2 messages and 8192. *Today: an
  empty assistant turn.*
- `missingPartsAreRepairedNotAccepted` — `{"tldr":"t"}`: 2 calls; the repair carries the answer and
  names overview, action_items, per_speaker_highlights. *Today: accepted after 1 call.*
- `keyDriftCountsAsMissingOverview` — `"summary"` in place of `"overview"`: the repair names only
  overview. *Today: accepted.*
- `blankTLDRIsIncomplete`. *Today: accepted.*
- `persistentMissingPartsThrowIncomplete` → `.incomplete(missing: ["overview"])`. *Today: accepted.*
- `rejectedBiggerRetryThrowsTruncated` — a cut-off, then `OpenRouterError.httpError(status: 400, …)` →
  `.truncated`. *Today: the HTTP error.*
- `customBudgetIsSentAndDoubled` — `maxOutputTokens: 300` → 300, then 600. *Today: no such init.*
- `unterminatedJSONTable` — `{"a":"b`, `{"a":["x"`, `{"a":"b\"`, a fenced partial → true; `{"a":"b"}`,
  `{}`, `{"a":1} tail`, `Sure! {`, `""` → false.
- `errorCopy` — `.truncated` says "cut off"; `.incomplete(["overview", "action_items"])` → "(no
  overview, action items)"; `.invalidJSON(snippet: "")` → "The model returned an empty answer."
- *Lock:* a complete answer with empty lists, a blank overview and camelCase keys is accepted on the
  first call.

`SummaryDecodeTests.swift`: `summarizeThrowsWhenTruncationPersists` (`:302-322`) now expects
`.truncated` (was `.invalidJSON`).

`OpenAICompatibleClientTests.swift`, *lock*: `"content": null` + `"length"` returns an empty completion
with `finishReason == "length"`, not `noContent`.

`MeetingPipelineSummaryTests.swift` (new; a file-private fake `Transcriber` like `CostTests.swift:178`):

- `failedSummaryDropsProvenance` — a failing summarizer and metadata with `model: "m"`,
  `summaryProvider: "openrouter"`: the saved meta has neither, there is no `summary.json`, and
  `summaryError` is set. *Today: both kept.*
- *Lock:* a successful summary keeps both.

App (no test target): `swift build --package-path app`, then the checklist.

### Manual checklist

1. `swift build && swift test` — green.
2. `cp -R` a transcribed meeting folder to a scratch path; `swift run kleoth summarize <copy>
   --provider openrouter --max-output-tokens 64` → "The summary was cut off…", non-zero exit, the
   copy's `summary.json` unchanged (`shasum` before and after). Two small paid calls.
3. The same copy without `--max-output-tokens` → a summary is written.
4. Settings → Accounts → OpenRouter, summary model `z-ai/no-such-model`. On a transcribed meeting with
   no summary, click Summarize → the card "Summary failed: OpenRouter returned HTTP 4xx…", the row's
   Failed chip, "No summary yet" still there.
5. Transcribe an untranscribed recording with that bogus model → the same card after transcription;
   its `meta.json` has no `model` / `summary_provider`.
6. Restore the model; Summarize → the summary appears; card and chip gone.
7. `pkill -x Kleoth; open -a Kleoth --args -KleothSimulateFirstRun YES` → the welcome window.
8. Skip setup → Start your first recording → the permissions step. I understand → Continue → Continue
   → Start → recording (menu-bar icon), the window closes. Stop it.
9. Repeat 7; Skip setup → Done. Press the record hotkey (if one is set) → Before you record; Not now →
   nothing records.
10. `open kleoth://record` → the window; I understand — start recording → recording; stop it.
11. Relaunch without the flag → no welcome window; the hotkey records at once.
12. Summarize latest targets the newest meeting only. With auto-transcribe on, record a few seconds,
    stop, and at once `open kleoth://summarize-latest`: it starts nothing (the new meeting's own
    run carries on), and the previous meeting's `summary.json` is unchanged (`shasum` before and
    after). With auto-transcribe off,
    record and stop, then `open kleoth://summarize-latest`: the status line says "The newest meeting
    isn't transcribed yet."

## 7 Out of scope

- Keeping a partial summary from a cut-off answer (§9 Q1).
- Detecting a local server's input cut-off (§9 Q4) — a README line only.
- Persisting a summary failure in `meta.json`: the card lives in memory like every meeting error, a new
  key would land beside sibling tracks' metadata work, and Summarize covers the relaunch case.
- Summarizing again a meeting that has a summary; a per-meeting model pick.
- Routing Summarize through the pipeline queue (it runs no WhisperKit).
- Same-tier re-transcription: whoever adds one must archive or clear the root summary first (§2.3).
- The dictation polisher's truncation handling (track 1); adapter finish-reason mapping (the
  assessment no longer depends on it).
- Screen-recording consent (§9 Q6); other start failures inside onboarding (§3.5 item 3).

## 8 Tasks

1. **Core + CLI** — `Summarizer.swift` (assessment, retry shapes, errors, `maxOutputTokens`),
   `OpenRouterClient.swift` (doc comment), `MeetingPipeline.swift` (provenance), `Kleoth.swift`
   (`--max-output-tokens`); tests `SummaryCompletenessTests.swift` and `MeetingPipelineSummaryTests.swift`
   (new), `SummaryDecodeTests.swift`, `OpenAICompatibleClientTests.swift`. No dependencies.
2. **App: summary surfaces** — `RecordingController.swift` (`summarize(_:)`, summarize-latest
   delegates, summary failures pinned in the three pipeline branches), `MeetingDetailView.swift`
   (Summarize button). Compiles without 1 (it only passes strings), so it can run in parallel.
3. **App: consent window** — `RecordingController.swift` (`consentRequest`, the launch argument),
   `KleothApp.swift` (scene, label), `ConsentView.swift` (window mode). Shares
   `RecordingController.swift` with 2 in disjoint regions: run after 2, or in its own worktree and merge.
4. **Docs + verification** — `CHANGELOG.md`; `README.md` (Ollama needs `OLLAMA_CONTEXT_LENGTH` of 32768
   or more for long meetings; `--max-output-tokens`); `CLAUDE.md` (State: the two review bugs are done;
   Key decisions: the completeness rule and the consent window; Gotchas: Ollama's `/v1` ignores
   `num_ctx`; the simulate argument); both package builds, `swift test`, an independent review. After 1–3.

## 9 Open questions

1. **Partial summaries.** Fail, keep the transcript and offer Summarize — or save what arrived under an
   "incomplete" banner? *Default: fail.* Salvaging cut-off JSON needs a lenient parser, and an
   incomplete summary is exactly what gets trusted by mistake.
2. **Reasoning on the retry.** Ask for `reasoning: low` when the first answer came back empty and cut
   off? *Default: yes, only then.* That is the documented reasoning-exhaustion symptom, and low effort
   took GLM to 0 reasoning tokens in the polish measurements. On Anthropic models it would switch
   thinking on, but they can't reach this case unless thinking is already on.
3. **Summarize button.** On every transcribed meeting without a summary? *Default: yes, and not on
   meetings that have one.* Without it the only retries are a paid cloud re-transcription or the CLI.
4. **Local input cut-off.** *Default: not in this fix* — a README line now; later, compare the
   answer's `usage.prompt_tokens` with the prompt estimate, once a live Ollama run shows whether
   prompt-cache hits under-report tokens (which would raise false alarms).
5. **Consent from the hotkey, URL or intent.** A small window that starts the recording on "I
   understand" — or reopen onboarding at the permissions step? *Default: the window.* The user asked to
   record; three onboarding steps is a detour, and onboarding is being redesigned.
6. **Screen-recording consent.** *Default: unchanged here; decide in the redesign.* It is a separate
   feature behind its own Screen Recording permission, and gating it now changes the pill's Record
   while track 2 is reworking the pill.
7. **`-KleothSimulateFirstRun YES`.** *Default: yes.* Without it neither this fix nor the redesign can
   be checked on this Mac short of a second macOS account; it is launch-only and persists nothing.
