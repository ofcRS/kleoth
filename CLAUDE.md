# Kleoth — project context & state

Local-first, bot-free macOS meeting recorder (open-source tl;dv / Fireflies alternative).
Captures system audio + mic locally → transcribes → summarizes → writes Markdown/JSON the
user owns. Native Swift 6 / SwiftUI menu-bar app + a `kleoth` CLI.

_Last updated: 2026-09-03. This file is living context for future sessions — keep it current._

## Environment
- macOS 26.5 (Tahoe), Apple Silicon, Swift 6.3.2, Xcode 26.5. Git repo (root `.git`).
- Deployment floors: KleothCore/CLI = macOS 13; app (`app/`) = macOS 14.4. App bundle
  `LSMinimumSystemVersion` = 14.4. Liquid Glass bits gated behind `if #available(macOS 26, *)`.

## Architecture — two SwiftPM packages
**Package 1 (repo root)** — `platforms: [.macOS(.v13)]`, dep: swift-argument-parser only.
- `KleothCore` (lib): Models, `HTTPTransport` seam, `Transcription` (ScribeClient, Multipart,
  TranscriptNormalizer, **Transcriber protocol**), Summarization (OpenRouterClient, Summarizer),
  Rendering, SpeakerMapping, Storage (MeetingStore), Config (Credentials, Settings), Pipeline
  (MeetingPipeline).
- `kleoth` (exe): subcommands `transcribe`, `summarize`, `rename`, `render`. (Slack removed 2026-06-08.)
- `KleothCoreTests` (51 tests, all green).

**Package 2 (`app/`)** — `platforms: [.macOS("14.4")]`, deps: `..` (KleothCore),
`sindresorhus/KeyboardShortcuts`, `argmaxinc/argmax-oss-swift` (WhisperKit @ 0.18.0).
- `KleothCapture` (lib): Recorder (writes `mic.m4a` + `system.m4a`, builds 2-channel
  `meeting.m4a`), MicCapture, SystemAudioTap (Core Audio process tap), ScreenshotCapture,
  **LocalTranscriber** (WhisperKit), **DictationCapture** (own AVAudioEngine input tap → temp m4a).
- `KleothApp` (exe): MenuBarExtra agent, `RecordingController` (`@MainActor`, owns capture +
  pipeline, app-lifetime `shared`), `DictationController` (`@MainActor`, see "Dictation" below),
  `AppConfig` (Settings/Credentials + Keychain overlay, shared by both controllers), Views
  (MenuView, HistoryView, MeetingDetailView, Settings, Consent, SpeakerRename, Dictation*),
  `Dictation/` (hotkey monitor, pill panel, text inserter), App Intents, `kleoth://` URL scheme,
  global hotkey.
- `taptest` (exe): dev probe for the audio tap.
- `localtranscribe` (exe): headless recovery tool — re-transcribe a meeting folder with the
  same engine the app uses. `localtranscribe <meeting-dir> [scribe]`.
- `dictate` (exe): headless dictation pipeline probe — record N s → prepare → Scribe → polish,
  print the result, no paste. `dictate [seconds] [--transcriber scribe] [--model <slug>] [--no-polish]`.
- `app/Package.swift` declares the root dependency as `.package(name: "kleoth-app", path: "..")` —
  the explicit `name:` is what lets the app package build from a worktree/checkout NOT named
  `kleoth-app` (SwiftPM otherwise derives the identity from the directory name).

## Transcription model (the core design — decided with the user)
Two tiers, engine-agnostic via the `Transcriber` protocol (`var usdPerHour`, `transcribe(fileURL:options:)`):
- **Tier 0 — default, free, on-device:** `LocalTranscriber` = WhisperKit (Whisper Core ML / ANE).
  Multilingual with **auto language detection** (handles **Russian** — the user's primary
  meeting language — which Apple's `SpeechTranscriber` does NOT; Apple supports only 8 langs,
  no `ru`, which is why we chose WhisperKit over Apple). Default model
  `large-v3-v20240930_626MB`. $0, nothing leaves the machine.
- **Tier 1 — on-demand SOTA:** ElevenLabs Scribe (`ScribeClient`, $0.22/audio-hour). Surfaced as
  the **"Fully transcribe"** action in MeetingDetailView (with spend confirmation). For 2-channel
  captures it uses `ChannelAttributedScribeTranscriber`: mic+system are **mixed to one mono file**
  (`ChannelAudio.mixToMono`, resampled to a common rate) sent as a single channel — **1× cost &
  correct duration** (Scribe sums/bills per channel, so a 2-channel upload was 2×). Scribe runs
  **with diarization ON**; we then map each diarization **cluster** to You/Them by **per-cluster
  channel energy** (`ChannelAudio.envelope` → `ChannelAttribution.mapDiarizedSpeakers`), falling
  back to per-word energy (`assignSpeakers`) only if Scribe returns <2 clusters. Deciding the
  channel **once per cluster** (not per word) keeps Scribe's coherent voice turns and stops
  mid-utterance speaker flips. **A/B on a live RU meeting (2026-06-03):** this hybrid scored
  **96.2%** You/Them vs multichannel ground truth, beating per-word energy (94.4%) and raw Scribe
  diarization (90.4%). The earlier "Scribe diarization = 61.8%" finding was on the mono mix
  **without** the cluster→channel map and is superseded. (Multichannel — one Scribe pass per
  channel — is exact and captures overlap, but costs 2×; rejected for the 1× mono path.)
- **You vs Them is free:** local transcribes mic & system as **separate channels** → `speaker_0`/
  `speaker_1`; Scribe uses the mono diarization + per-cluster channel-energy path above. The app
  writes a default `speakers.json` `{speaker_0: "You", speaker_1: "Them"}` for 2-channel meetings.
- `MeetingMetadata.transcriptTier` ∈ `TranscriptTier.local` (`"local-whisper"`) /
  `.sotaScribe` (`"sota-scribe"`). Badges in History + Detail read **"On-device" / "Cloud"**
  (`TranscriptTier.label` — was "Local"/"SOTA", jargon the user vetoed 2026-06-04); stored tier
  strings are unchanged.
- **Duration is wall-clock, derived from the audio file** (`AudioProbe.durationSeconds`, used in
  the pipeline + History list), never the STT-reported value — engine-robust, and fixes legacy
  2× Scribe meetings on next view.

### WhisperKit specifics
- `WhisperKit(WhisperKitConfig(model:, useBackgroundDownloadSession: true))` — background session
  avoids the 60s URLSession request-timeout that killed the in-line first-run download.
- **Prewarm at launch:** `RecordingController.prewarmTranscriptionModel()` (called from `init`)
  downloads the model in the background, surfacing `modelDownloadProgress` in the popover.
  First run pulls ~600 MB once, then offline.
- `LocalTranscriber.downloadModel(useBackgroundSession:progress:)` is the download entry point.
- **Language (⚠️ gotcha):** WhisperKit's `DecodingOptions.detectLanguage` defaults to
  `!usePrefillPrompt` = **`false`**, so `language: nil` alone silently resolves to **`"en"`** —
  this made RU meetings transcribe in English. `LocalTranscriber.resolveLanguage` now runs ONE
  global `pipe.detectLanguage(audioPath:)` pass (most-confident channel wins, short-circuits at
  ≥0.85) and forces that language across all VAD chunks; `detectLanguage: true` is only the
  last-resort fallback. The resolved code is also returned as `ScribeResponse.languageCode` (via
  `resolvedLanguage ?? …`) so the summarizer writes in that language. Pinnable via Settings →
  `transcription_language` (Keychain), `nil`/`"auto"` = detect. Verified live: RU meeting → `ru`.

## Dictation (fn+shift voice typing — v1, 2026-09-03)
Design doc = `docs/plans/2026-09-03-dictation.md` (single source of truth; §3 is the binding
interface contract, §5.10 the controller design, §7 the error matrix, §8.2 the manual checklist).
- **Flow:** hold **fn+shift** → `DictationHotkeyMonitor` (NSEvent global+local monitors, needs
  `AXIsProcessTrusted()`) feeds the pure, tested `DictationChordMachine` (KleothCore) → `.armed`
  (mic on at key-down, no UI) → `.began` at 0.30 s (pill appears; double-tap within 0.40 s =
  hands-free `.toggledOn`) → release `.ended` → `DictationCapture.stop(min 0.5 s)` → off-main
  `prepareForUpload` (`ChannelAudio.mixToMono` with a nonexistent 2nd channel = mono + loudness
  + peak normalize, 64 kbps) → **`any Transcriber`** (`ScribeClient`, `ScribeOptions.dictation`:
  `scribe_v2`, `no_verbatim`, diarize/audio-events off, ≤100 sanitized `keyterms`, 25 s
  `withTimeout`) → `DictationPolisher` (ONE OpenRouter call, json_schema, temp 0.2, 8 s budget,
  **non-throwing** → `.polished` or `.raw(reason)`; translation guard: model language ≠ Scribe's
  → raw) → `TextInserter` (full pasteboard snapshot → marked write → synthetic ⌘V via
  `CGEvent.post(.cgSessionEventTap)` → restore after 0.5 s iff `changeCount` still ours) →
  `DictationLogStore` actor append → `logRevision += 1` → pill `.done` (1 s) / `.warning` (3 s).
- **Controller:** `DictationController` (`@MainActor`, `shared`, `@EnvironmentObject` in views —
  never read `.shared` from SwiftUI). `Phase` idle/armed/listening/transcribing/polishing/inserting;
  `endSession()` is the ONLY place `phase`/`escapeCancels`/`isSessionActive` reset (called from
  the two listening exits + `run()`'s single `defer`, which also deletes both temp clips).
  Preflight at `.armed`: enabled → trusted → ElevenLabs key → mic not denied → no secure input →
  `capture.start()`; each failure is a sticky `.failed` pill (no spend, no log row). Chord while
  the pipeline runs → 1 s "Finishing the previous dictation…" then the phase's pill returns
  (a bare `.warning` would auto-hide mid-run). Esc cancels listening or the in-flight pipeline
  (`pipelineTask.cancel()` + `Task.isCancelled` checks after prepare/STT/polish so a cancelled
  polish never pastes). `.cancelled(.external)` mid-pipeline (trust lost) is a deliberate no-op —
  the paste then falls back to clipboard-only. **Machine ↔ phase resync:** every controller-side
  session exit the machine did not drive (`cancel()`, Esc while hands-free, `refuseWhileBusy()`)
  calls `monitor.abort()` — otherwise the machine parks in `.handsFree` and the next press is eaten. Pill `.openSettings` = `NSApp.activate` +
  `NSApp.sendAction(Selector(("showSettingsWindow:")))` (AppKit panel, no SwiftUI env — don't "fix").
- **Lifecycle:** `AppDelegate` hooks via `MainActor.assumeIsolated` (never a `Task` hop —
  `applicationWillTerminate` may exit first): `startIfEnabled()` (sweeps stale temp clips, installs
  monitors), `refreshTrust()` on `didBecomeActive` (+ the Settings section's 1 Hz poll) reinstalls
  monitors on grant; `shutdown()` on terminate. The monitor's own 30 s health timer tears down on
  trust loss. `eventTask` (one `for await` over `monitor.events`) lives for the app's lifetime
  across Settings off→on cycles.
- **Keys/files:** Keychain `dictation_enabled` ("true" strict, default off — existing installs stay
  off), `dictation_model` (default `DictationDefaults.polishModel`, passed through
  `ModelCatalog.migrating`); UserDefaults `dev.kleoth.dictation.pillPlacement`;
  `~/Kleoth/dictations/<yyyy-MM-dd>.json` (bare array, snake_case, oldest-first; costs stored,
  never shown); `~/.config/kleoth/dictionary.json` (≤1000 stored, ≤100 sent);
  `$TMPDIR/kleoth-dictation/{dictation,prep}-<uuid>.m4a` (deleted on every exit; 1 h sweep at launch).
- **Decisions:** Kleoth **stays un-sandboxed** (`CGEvent.post` is blocked under App Sandbox with no
  re-enabling entitlement — `app/bundle/Kleoth.entitlements` must never gain
  `com.apple.security.app-sandbox`; no Mac App Store path without rebuilding insertion). The
  **stable "Kleoth Self-Signed" identity is now required**, not just nice: Accessibility trust is
  bound to the code signature and would be lost on every rebuild otherwise. `kVK_ANSI_V` is
  hardcoded (QWERTY-family incl. RU; plain Dvorak/Colemak deferred). fn+shift with any extra
  modifier never arms. `no_verbatim` always on, so stored `raw_text` is already filler-light.
  Translation-guard mismatch → raw + warning (revisit if it fires on real mixed RU/EN).
- **Probe:** `swift build --package-path app --product dictate && app/.build/debug/dictate 4`
  (prints a 20 Hz RMS meter, raw/language/billed duration/cost, polished/fallback reason).
  `log stream --predicate 'subsystem == "dev.kleoth" AND (category == "DictationHotkey" OR
  category == "Dictation")'` is the live hotkey/controller probe.

## Summarization
- OpenRouter chat-completions. **Default model: `z-ai/glm-5.3-flash`** = `ModelCatalog.defaultModel`
  (the ONE place the literal lives; `Settings.load`, `Summarizer.init` read it).
  `DictationDefaults.polishModel` is DIFFERENT since the latency pass: `google/gemini-3.5-flash-lite`
  (median 0.85–1.05 s per polish) with `fallbackPolishModel` = `ModelCatalog.defaultModel` (a test
  pins that equality) — see the 2026-09-03 latency bullet. **Verified live
  2026-09-03** (200 with strict `json_schema`, RU preserved). Chosen over `google/gemini-3.8-flash`
  because this account's ZDR guardrail 404s every `google/*` endpoint — see the data-policy note
  below; Gemini 3.8 stays selectable in `curatedFallback`. Was `google/gemini-3-flash-preview`
  (retired) and before that `openai/gpt-4.1-mini` (policy-404'd); both are in
  `ModelCatalog.retiredModels` and are migrated in memory on every `AppConfig` load and persisted to
  the Keychain the first time Settings opens. ⚠️ GLM 5.3 flash is a **reasoning model** and OpenRouter
  says reasoning "is mandatory for this endpoint and cannot be disabled" — expect ~100–500 reasoning
  tokens per call; polish latency measured 2.6–14 s (see the 2026-09-03 status block).
- The summary model is config: Settings → Keychain `default_model` (app), or `--model` (CLI).
- `OpenRouterClient` sends `provider: {require_parameters: true}` and requests **structured output
  via `response_format: {type: json_schema, strict}`** (the `MeetingSummary` schema, incl. a
  generated `title`), transparently falling back to `{type: json_object}` on a 400/404 (keeps
  no-train-provider compatibility). Summarizer keeps lenient JSON parse + one repair retry.
- **Output language follows the transcript:** the system prompt mandates writing every field in the
  transcript's language (never translating to English), and `buildUserContent` names the detected
  language via `Summarizer.languageName` (maps both Scribe `rus` and Whisper `ru` → "Russian"), so
  a RU meeting summarizes in RU. Was the root cause of RU meetings summarized in EN (the prompt
  never specified an output language, so the model defaulted to its instruction language).
- **Title from summary:** `MeetingSummary.title` becomes the meeting title only when the existing
  title is an auto-placeholder (`MeetingMetadata.isPlaceholderTitle` — "Meeting <date>" /
  "Recording <date>" / "Recording · …" / empty); calendar/user titles are preserved.
- **Summary shape (lean since 2026-06-04):** `MeetingSummary` = `title?`, `tldr`, **`overview?`**
  (detailed multi-paragraph prose — the "Summary" section), `action_items`,
  `per_speaker_highlights`. The old decisions / key_points / open_questions / suggested_tags were
  removed as slop at the user's request; legacy summary.json files still decode (extra keys
  ignored, `overview` nil → section omitted, arrays lenient-default to `[]`). Reading order
  everywhere (app view, summary.md): TL;DR → Summary → Action Items → Per-Speaker Highlights →
  Transcript. `maxOutputTokens` 8192.

### ⚠️ OpenRouter data-policy constraint (important, account-specific)
This account's privacy settings apply TWO guardrails, and `require_parameters: true` turns both
into **404s**:
1. **No-train:** `"No endpoints available matching your guardrail restrictions and data policy"`
   for `openai/*`, `mistralai/*`, `qwen/qwen3.x-max`, `x-ai/grok-*`.
2. **Zero Data Retention (since 2026-09-03):** `google/gemini-3.8-flash` returns **404
   `zdr-violation-by-account`** ("ZDR violation (account settings): 1 endpoint excluded") whenever
   the body carries **`temperature`** under `require_parameters` — with `json_schema` AND
   `json_object` alike (the parameter forces routing onto the one excluded endpoint). ⚠️ It is NOT
   "every Google endpoint" (an earlier note said so — wrong): the same body without `temperature`
   (= the Summarizer's) returns 200 on 3.8-flash, and `gemini-3.5-flash` / `gemini-3.1-pro-preview`
   return 200 with schema + temperature (re-probed 2026-09-03). Since the root fixer pass,
   `OpenRouterClient.complete`'s 400/404 retry drops `temperature` + `reasoning` (and downgrades
   `json_schema` → `json_object`), so a polish on 3.8-flash now succeeds on the second round trip
   instead of pasting raw. To avoid that extra round trip, relax the ZDR guardrail at
   https://openrouter.ai/settings/privacy.
- **Works (verified live 2026-09-03):** **`z-ai/glm-5.3-flash` = the shipped default** (200 with
  strict structured output, RU preserved, fillers removed; reasoning model, ~100–500 reasoning tokens
  per polish — OpenRouter rejects `reasoning: {enabled: false}` for it with 400 "Reasoning is
  mandatory for this endpoint"). Also fine under no-train (verified 2026-06): `deepseek/*` (v4),
  `z-ai/glm-*`, `moonshotai/kimi-*`, `minimax/*`, `meta-llama/*`.
- To use OpenAI/Mistral: enable **"Paid endpoints that may train on request data"** at
  https://openrouter.ai/settings/privacy (or stop sending `require_parameters`).
- The original "OpenRouter key doesn't work" report was THIS 404, not a bad key.

## Build / run
```bash
# Core + CLI
swift build && swift test                       # 86 tests
swift run kleoth summarize <dir> --model <slug> # re-summarize an existing meeting in place

# App
swift build --package-path app
bash app/setup-signing.sh                       # one-time: self-signed "Kleoth Self-Signed" cert
bash app/make-app.sh release                    # bundle + sign + install /Applications/Kleoth.app
pkill -x Kleoth; open -a Kleoth                 # relaunch

# Distribution
bash app/make-dmg.sh                            # → app/dist/Kleoth-<version>.dmg (drag-to-/Applications,
                                                #   Read Me, volume icon, signed; prints SHA-256)
# Public (Gatekeeper-clean) tier once in the Apple Developer Program:
#   KLEOTH_SIGN_IDENTITY="Developer ID Application: …" KLEOTH_NOTARY_PROFILE=<profile> bash app/make-dmg.sh
# Version comes from app/bundle/Info.plist CFBundleShortVersionString (0.1.0).

# Recovery / headless transcribe (NOTE: --product, not --target — see gotchas)
swift build --package-path app --product localtranscribe
app/.build/debug/localtranscribe <meeting-dir> [scribe]
```

## Meeting folder layout (`~/Kleoth/meeting-yyyy-MM-dd-HHmmss/`)
`mic.m4a`, `system.m4a`, `meeting.m4a` (2-channel combined) · `transcript.json` (raw Scribe or
synthesized) · `transcript.md` · `summary.json` · `summary.md` · `speakers.json` · `meta.json`
(always). One meeting = one folder. Folder name encodes start time. Since 2026-07-22 a meeting can
also hold `variants/<tier>/` (archived transcript set of the non-active tier + `variant.json`
sidecar: tier/model/language/cost) — the six root filenames stay THE active set; filesystem is the
source of truth for which tiers exist (no new meta key).

## Current status (2026-09-03 — dictation v1)
User-run 9-task workflow (T0 contract → T1–T7 in parallel worktrees → T8 integration), branch
`feat/dictation` (NOT merged to main yet). Design doc `docs/plans/2026-09-03-dictation.md`.
**Shipped (compile-checked, 237 core tests green, both packages build, release app installed):**
- KleothCore `Dictation/`: `DictationDefaults`, `DictationChordMachine` (18 tests),
  `ChordEdgeDetector` (5 tests), `Keyterms`,
  `DictationPrompt` + `DictationPolisher` (+ `Concurrency/Timeout.swift` `withTimeout`),
  `DictationLogEntry`/`DictationLogStore` (actor) / `PersonalDictionaryStore`, `PillGeometry`,
  `PasteboardPolicy`; `ScribeOptions.noVerbatim/keyterms` + `.dictation(keyterms:)`,
  `Multipart.writeBody(repeatedFields:)`, `OpenRouterClient: Sendable` + `temperature:`,
  `Settings.dictationEnabled/dictationModel`, `ModelCatalog.defaultModel/retiredModels/migrating`.
- KleothCapture: `DictationCapture` (+ `RenderLevel`/`RenderCounter`, `mixToMono(bitRate:)`).
- KleothApp: `Dictation/` (DictationTypes = contract, DictationController, DictationHotkeyMonitor,
  AccessibilityPermission, DictationPanel/PillController/PillModel, TextInserter,
  PasteboardSnapshot, InsertionEnvironment), `AppConfig`, Views (DictationPillView,
  DictationsListView, DictationDetailView, SettingsDictationSection; HistoryView scope picker
  Meetings | Dictations; SettingsView mounts the section), MenuView "Dictation needs
  Accessibility access" line (enabled + untrusted only), AppDelegate hooks, `dictate` probe.
- **T8 live probes (this Mac, 2026-09-03):** `dictate 3` → capture 3.2 s @ 48 kHz → prep 87 KB →
  Scribe **200** in 1.6 s (ambient audio → "Why have…", `eng`) → polish **404 zdr-violation** with
  the THEN-default `google/gemini-3.8-flash` → raw fallback; temp dir empty afterwards.
  `say -v Milena "Привет, это проверка диктовки, короче нужно задеплоить пул реквест завтра утром"`
  + `dictate 6 --model z-ai/glm-5.3-flash` → Scribe `rus` in 1.3 s, raw "Привет! Это проверка
  диктовки. Короче, нужно задеплоить pull request завтра утром" → polished in 2.6 s
  "Привет! Это проверка диктовки. Нужно задеплоить pull request завтра утром." (filler removed,
  English term kept, translation guard passed on `rus` vs `ru`), $0.00024. Pipeline plumbing
  through the `Transcriber` seam is therefore verified end-to-end; only the default model is the
  account-level blocker above. ElevenLabs' 2026-08-17 `payment_issue` is gone.
- **Decisions recorded:** Kleoth stays un-sandboxed; stable signing identity required; QWERTY-family
  layouts assumed; fn+shift+⌘/⌥/⌃ never arms; translation guard kept.
- **Default model switched to `z-ai/glm-5.3-flash` (fixer pass, same day):** `ModelCatalog.defaultModel`
  AND `DictationDefaults.polishModel` (test pins them equal); `google/gemini-3.8-flash` stays in
  `curatedFallback` (selectable, not default); `retiredModels` still map the two dead slugs → the
  default. Rationale: the T8 probes above showed the Gemini default 404s on this account (ZDR),
  making every dictation raw-fallback and every summary fail. Design doc §10.3 item 5 records it.
- **Reasoning cap on the polish call (measured, model-gated):** `OpenRouterClient.complete(…,
  reasoning:)` is a new optional arg (`OpenRouterReasoning`, nil → body unchanged; a test pins the
  Summarizer body to exactly `model/messages/max_tokens/provider/response_format`). `DictationPolisher`
  sends `reasoning: {effort: "low"}` ONLY for slugs in `DictationDefaults.reasoningCappedModels`
  (= `["z-ai/glm-5.3-flash"]`). Live numbers (verbatim `DictationPrompt.system`, RU + EN samples,
  json_schema strict, temperature 0.2, `require_parameters: true`, 2026-09-03): baseline glm-5.3-flash
  = 104–362 reasoning tokens, **4.8–14.2 s (mean 8.4 s RU / 7.4 s EN — one RU run blew the 8 s
  budget)**; `effort: low` = **0 reasoning tokens, 1.5–4.9 s (mean 3.2 s over 9 runs)**, byte-identical
  correct output (fillers gone, "Anna, sorry, Boris" self-correction applied, RU stays RU).
  `enabled: false` → 400 "Reasoning is mandatory for this endpoint"; `exclude: true` only hides the
  tokens (155–272, 6.7–9.4 s). ⚠️ NOT a general speed-up: the same body **404s on
  `meta-llama/llama-3.3-70b-instruct`** ("No endpoints found that can handle the requested
  parameters") and *enables* reasoning on `deepseek/deepseek-v4-flash` (0 → 216 tokens, 4.9 → 9.5 s)
  — hence the allowlist. Also observed: `z-ai/glm-4.7` and `moonshotai/kimi-k2.6` return EMPTY
  content under the strict dictation schema (reasoning eats the 1024-token cap, 17–28 s) — poor
  polish picks; they stay in `curatedFallback` for summaries (8192-token budget) untested.
  `polishTimeout` stays 8 s (max capped run 4.9 s). Probe scripts were scratch-only (not committed).
- **Pill redesign (same day; user: "more like Wispr Flow — visible when inactive, animates in on the
  hotkey, no words"):** `DictationPillState.idle` added — the compact resting capsule (24 pt, five
  breathing dots) stays on screen whenever the hotkey is armed; `DictationPillPresenting.setResting(_:)`
  is mirrored from `DictationController.isMonitoring` (`didSet`), and `dismiss()` now collapses to
  `.idle` instead of hiding (hides fully only when resting is off: disabled / untrusted / quit).
  Motion phases carry no text: listening = 14-bar live waveform (bell-weighted mic level + slow drift;
  accent dot = hands-free), transcribing = travelling white wave, polishing = accent-tinted faster
  wave, done = green check for 1 s. Only `.warning` / `.failed` show words (they need a reason / an
  action). Surface is a dark capsule (`PillStyle`, white ink) regardless of appearance — NOT the app's
  material, deliberately. `TimelineView(.animation)` is mounted only in active phases (resting costs
  nothing); Reduce Motion → static bars/dots. Panel sizes per phase in
  `DictationPillController.panelSize/capsuleHeight`. Hover `.help` + VoiceOver keep the sentences.
  ⚠️ Compile-checked only — the user is the visual reviewer (relaunch to see it).
- **Pill placement v2 (same day; user: "inactive should be small and half outside the screen, and
  emerge from there on the hotkey"):** ONE anchor per pill (saved `PillPlacement`, else bottom-center
  just above the screen's bottom edge — `defaultBottomInset` 96 → **26**, over the Dock like Wispr
  Flow). Active phases sit centered on the anchor; `.idle` is the anchor slid into the **nearest
  screen edge** until the panel center is ON the edge (`PillGeometry.restingOrigin` /
  `nearestEdge`, tested) → exactly half the 68×22 capsule peeks in. A chord animates the frame
  back to the anchor (`setFrame(_:animated:)`, 0.3 s, slight overshoot); `dismiss()` sinks it back;
  a fresh show starts tucked and rises. The idle capsule has NO content (anything centered would be
  cut in half) — a `RestingSheen` gradient breathes over it. Active bounds = `PillGeometry.bounds`
  (screen frame minus the menu bar, INCLUDING the Dock strip; `visibleFrame` is no longer used for
  placement), `DictationPanel.constrainFrameRect` returns the frame untouched so AppKit can't nudge
  the tucked panel back on screen, and `currentDisplayId` tracks the anchored screen because a
  straddling frame can't be resolved from geometry. Dragging pops the resting pill fully on screen
  (clamped), the drop becomes the new anchor, and an idle pill tucks back on release. 244 tests.
  Follow-up (user feedback after seeing it): (a) an EMPTY transcript now just `pill.dismiss()`es
  (was a "Nothing was heard." warning — "worst UI"); (b) a tab tucked into a LEFT/RIGHT edge stands
  up — `panelSize(for: .idle, edge:)` swaps w/h, the view applies `rotationEffect` (±90°, 180° on
  top; sheen's bright end faces inward) AFTER the hit shape + gestures so the vertical tab stays
  clickable, and the rotation unwinds as the bar rises; `DictationPillModel.restingEdge` carries the
  edge, `PillGeometry.restingOrigin(…edge:in:)` takes it explicitly; (c) idle rim = white 0.42 @ 1 pt
  (`PillStyle.restingRim`), active keeps the hairline.
  Second follow-up (user: "it should stay vertical on a side edge in the active state too" + "the
  size-change animation is ugly — make it beautiful, research best practice"): (a) `DictationPillModel.edge`
  now rotates the capsule ±90° in EVERY phase on a side edge (left reads bottom-to-top like a spine
  label; top edge stays horizontal with the sheen flipped); `layout(for:edge:on:)` swaps panel
  dimensions for every phase there. (b) **The panel frame is never animated any more** — AppKit's
  timer-driven `animator().setFrame` fighting SwiftUI's own spring on the capsule was the jank.
  Stage technique: `transition(to:phase:)` sets the panel instantly to the UNION of the current and
  destination rects, re-expresses the capsule's current position as `model.offset` (relative to the
  stage center, y-down) under `disablesAnimations`, then on the NEXT main-queue callout runs ONE
  `withAnimation(.spring(duration: 0.45, bounce: 0.22), completionCriteria: .logicallyComplete)` that
  moves `offset` + switches `phase` (size, rotation, content transitions all ride that spring — the
  view has NO `.animation` modifiers of its own), and the completion `settle()`s: panel = destination
  rect, offset = 0, same turn, invisible. `transitionGeneration` guards stale completions; `beginDrag()`
  settles first; `finishHide` resets. The capsule is `.fixedSize()` (the stage / a side panel is not its
  size) and the text label gets an explicit `labelWidth` (measured + capped at 60% of the screen axis)
  so long messages still truncate. Reduce Motion → the panel just jumps.
- **Polish latency pass (same day, after the user reported "polishing takes too long"; the user had by
  then turned every ZDR toggle OFF at openrouter.ai/settings/privacy, so google/* is reachable again):**
  the `dictate` probe gained a polish-only benchmark — `dictate --text "<raw>" [--language rus]
  [--runs N] [--model <slug>] [--reasoning minimal|low|medium|high]` — that times the REAL
  `DictationPolisher` (`reasoningOverride` init param). Medians over 4 runs, RU sample, strict schema:
  **`google/gemini-3.5-flash-lite` 0.85–1.05 s** ($0.0006, correct) · `gemini-3.8-flash` + low 1.45 s
  (uncapped: cut off / 8 s timeout — it thinks) · `gemini-3.7-flash` + minimal 1.55 s · `gemini-3.5-flash`
  + minimal 1.85 s (uncapped 6.5 s) · `z-ai/glm-5.3` 1.75 s · **`z-ai/glm-5.3-flash` + low 3.6–4.1 s
  (the previous default — what the user felt)** · `deepseek-v4-flash-0731`, `qwen3.7-flash` → 8 s
  timeout every run. Shipped: `DictationDefaults.polishModel = google/gemini-3.5-flash-lite`;
  `fallbackPolishModel = z-ai/glm-5.3-flash` (+ `minimumFallbackBudget` 2 s) — `DictationPolisher`
  tries it once when the primary fails with an HTTP error (guardrail 404 after the client-side relaxed
  retry, 429, 5xx) and ≥2 s of the 8 s budget remain; never after a timeout/cancel/bad answer
  (tests: `httpFailureOnThePrimaryFallsThroughToTheFallbackModel`, `fallbackIsNotTried…` ×2);
  `reasoningCappedModels: Set` → `reasoningCaps: [slug: Effort]` (glm-5.3-flash low, gemini-3.8-flash
  low, gemini-3.7/3.5/3.5-lite minimal; `reasoningCappedModels` kept as a computed Set);
  `ModelCatalog.curatedFallback` gained the lite slug. Summary default unchanged (glm works under
  every privacy setting; no latency pressure). Live after the change: default 0.76–1.29 s over 5 runs;
  bogus primary → glm fallback 2.3 s (one glm run then hit the remaining-budget timeout — glm variance).
- **Review pass (same day, 5-dimension multi-agent review — concurrency / macOS APIs / pipeline / UI /
  compliance; every finding adversarially verified):** 19 findings confirmed (5 medium, 14 low) and
  ~50 suspected items checked and found CORRECT (recorded in the review brief; e.g. `shared` is set
  before `applicationDidFinishLaunching`, monitors don't double-fire, `withTimeout` cancels
  properly, `vDSP_measqv` is already the mean). **All 19 applied** (app fixer, this pass):
  (1) `monitor.abort()` wired at every controller-side exit the machine didn't drive — `cancel()`
  listening + pipeline branches, `handleEscape()` listening, `refuseWhileBusy()` — and
  `DictationChordMachine` `.abort` from `.handsFree` now lands in `.idle` (keys are already up;
  was `.blocked` → the next press was eaten as `.toggledOff`); (2) new KleothCore
  `ChordEdgeDetector` (tested): releasing ⌘ off fn+shift+⌘ no longer reads as a chord-down (it
  armed, or from `tapWindow` started hands-free) — the "add ⌘ mid-hold commits" behavior (§8.2 #7b)
  is deliberately KEPT; (3) `PasteboardSnapshot.capture` runs off-main on the serial
  `PasteboardReader` actor under `PasteboardPolicy.captureTimeout` (0.4 s; expiry = "no snapshot to
  restore"), with a per-item flavor budget (`typesToCapture`, 6 non-preferred + text/url/file-url
  always) and an early stop at 12 MB — a lazy Photoshop/Figma clipboard no longer freezes the main
  thread; (4) Scribe HTTP failures show "Transcription failed (HTTP 401)." (body → os.Logger),
  `DictationPillFault.message` is capped at 140 chars, the panel width is capped to the screen
  (`PillGeometry.maxPanelWidth`, tested) and the pill label tail-truncates (was `.fixedSize()` →
  a 512-byte body pushed the ✕ off-screen); (5) popover → History forces the Meetings scope via
  `RecordingController.meetingsHistoryRequest` (the `selectedMeetingID` observer lived on the
  unmounted meetings branch while Dictations was showing); lows: Settings writes dictionary.json
  only if the editor text changed (a malformed file was being overwritten with `[]` on close),
  `URLError(.cancelled)` from Esc mid-upload dismisses instead of a sticky "Network error", the
  monitor's health-timer teardown now reports `onTrustLost` → `refreshTrust()` (popover banner
  appears immediately), pill hit shape is the capsule (the 18 pt shadow margin no longer swallows
  clicks), `logStore` rebinds when Settings moves the output folder (`syncLogStore()`),
  `Transcriber.modelIdentifier(for:)` (default = type name; Scribe = `options.modelId`) replaces the
  hard-coded `scribe_v2` in the log row, detail pills read "Cloud transcription"/"Cleaned up" with
  the slug in `.help`, header no longer repeats the app name, dictionary caption interpolates
  `Keyterms.maxTerms` and drops the "20% surcharge" figure, dictation delete failures alert + always
  reload (`logRevision` bumped in a `defer`), `appEvent` identity map deleted, `RenderLevel` doc now
  says "deliberate benign race" (a relaxed atomic needs macOS 15), entitlements comment names
  `CGEvent.post`. NOT done: wiring `isMonitoring`/`isSessionActive` into a view (still unread
  published state — harmless). 237 core tests green; both packages build; `dictate 3` on the default
  model → Scribe `rus` + polish OK in 2.25 s, temp dir empty; release app reinstalled (running
  instance NOT killed). Gotcha: adding a KleothCore source file is invisible to a warm
  `app/.build` until `app/.build/arm64-apple-macosx/debug/description.json` is deleted.
- **Three unverified review findings, traced and fixed (same day, after the pass above — the
  original verifier agents crashed, so each was re-traced from the code first):**
  1. **Quit mid-pipeline no longer strands mic audio:** `DictationController.inFlightClips` records
     every temp file the run owns (the raw clip, and the `prep-<uuid>.m4a` destination — now named by
     the new `DictationCapture.preparedURL(for:)` and passed into `prepareForUpload(_:outputURL:)`
     *before* the detached prep starts), so `shutdown()` deletes them SYNCHRONOUSLY. `cancel()` only
     marks `pipelineTask` cancelled; `run()`'s `defer` needs a main-actor hop a terminating process
     never runs, and `sweepStaleClips(olderThan: 3600)` then skipped the leftovers for an hour.
  2. **A mid-utterance device switch is no longer silent:** `DictationCapture`'s
     `.AVAudioEngineConfigurationChange` handler is now `handleConfigurationChange()` — it zeroes
     `level` (the 20 Hz poll was rendering a frozen RMS, so the pill looked live after the mic had
     stopped) and sets `DictationCaptureResult.interrupted`, which `run()` turns into
     `.warning("The microphone changed mid-dictation — only part was captured.")` on the pasted
     result. A polish fallback reason and the clipboard fallback still outrank it. Restarting on the
     new device stays out of scope.
  3. **"Reset pill position" acknowledges the click:** `resetPosition()` animates only a visible
     pill, which it never is while Settings is open, so the button now flashes "Position reset" for
     1.5 s (`SettingsDictationSection.resetPillPosition()`, the `flashCopied()` idiom).
  237 core tests green (unchanged — `DictationCapture` lives in the app package, which has no test
  target); both packages build; release app reinstalled (running instance NOT killed).
  ⚠️ Not runtime-verified: all three need a human (quit mid-pipeline + `ls $TMPDIR/kleoth-dictation`,
  unplugging a mic mid-utterance, the Settings button by eye).
- **Known leftovers (small):** CLI `summarize`/`rename` + `localtranscribe` bypass variant archiving
  (from 2026-07-22). `docs/CODE-REVIEW.md` still local/uncommitted.
- ⚠️ **NOT runtime-verified (honest list):** everything that needs the signed bundle + a human —
  the hotkey monitor live (chord detection, fn/🌐 double-tap emoji-picker caveat, trust-loss
  teardown, local monitor while a Kleoth window is key), the real ⌘V paste into real apps,
  secure-input refusal + 0.5 s clipboard restore + Maccy transient markers, the pill by eye (activation
  policy, Spaces/full-screen, second display, drag/clamp/persist, VoiceOver, Reduce Motion), the
  Settings section (trust polling, dictionary file write, delete confirmation), History scope switch
  not re-running the meetings reload, the model migration on this install, "at most one Keychain
  prompt", and whether an Accessibility grant takes effect without relaunch. The release app was
  reinstalled but the RUNNING instance was not killed — relaunch to pick it up.
- **TODO for the user — §8.2 manual checklist (unchecked; record pass/fail here):**
  prereq `bash app/setup-signing.sh` once, `bash app/make-app.sh release`, `pkill -x Kleoth; open -a
  Kleoth`, `codesign -dv` shows "Kleoth Self-Signed". Added by the review pass (§8.2 #7c/#8b):
  fn+shift+⌘ with ⌘ released FIRST must not arm/start hands-free; hands-free → Esc (and → pill ✕)
  → the next single hold must arm on the FIRST press; double-tap twice mid-pipeline → the first
  press after it settles arms.
  1. Settings → Dictation toggle on before granting → system prompt; row "needs access"; popover button; chord dead.
  2. Grant in System Settings, return → row flips green without relaunch; chord works (else relaunch + note here).
  3. `log stream --predicate 'subsystem == "dev.kleoth" AND category == "DictationHotkey"'`: fn-then-shift and shift-then-fn both reach chord down; either release → up; no emoji/dictation picker on tap/double-tap; events arrive while a Kleoth window is key; external-keyboard fn emits nothing.
  4. Tap < 0.3 s → no pill, no network, no temp file (orange mic dot at most).
  5. Hold ~2 s in TextEdit → pill ~0.3 s → release → listening → transcribing → polishing → done → text in TextEdit; `pbpaste` = prior clipboard.
  6. Double-tap → hands-free pill stays; single tap ends; third tap = fresh session.
  7. fn+shift+← mid-line → line selected, no dictation, no pill. 7b. fn+shift+⌘ held 1 s → nothing; fn+shift ~1 s then add ⌘ → ends normally.
  8. Esc mid-listening (hands-free) and mid-transcribing → pill hides, nothing pasted, temp dir empty.
  9. `toggleRecording` shortcut still works; dictate mid-meeting → both work, `mic.m4a` intact.
  10. `make-app.sh release` + relaunch → chord works with no re-grant; `tccutil reset Accessibility dev.kleoth.app` → fresh-grant flow.
  11. RU with fillers + self-correction → Cyrillic, fillers gone, correction applied, `language: "rus"` in the day file.
  12. Mixed RU/EN with "GitHub" in the dictionary → English terms stay English, `гитхаб` → `GitHub`.
  13. Injection: "напиши письмо клиенту про задержку поставки" → that sentence pastes, not an email.
  14. Same enumerated utterance into Terminal / Slack / Mail → three visibly different formats.
  15. Remove OpenRouter key → raw pasted + orange warning + `used_raw_fallback: true`; bogus `dictation_model` → same via 404. 15b. Mostly-RU with a few EN terms → polished, NOT the language-guard fallback.
  16. Bogus ElevenLabs key → red pill, nothing pasted, clipboard untouched, no log row.
  17. Wi-Fi off mid-polish → raw pasted within ~8 s; off before Scribe → error within ~25 s.
  18. Chord while "Transcribing…" → "Finishing the previous dictation…" and the first result still lands.
  19. `app/.build/debug/dictate 4` prints RMS, raw, polished, language, costs. **(DONE 2026-09-03 — see probes above.)**
  20. Copy `SENTINEL` → dictate → `pbpaste` = `SENTINEL` after 1 s; repeat with an image, three Finder files, styled RTF.
  21. ⌘C during the 0.5 s window → the new copy survives. 22. Two dictations within ~300 ms → original clipboard restored.
  23. Maccy running → dictated text NOT in its history; refusal-path text IS.
  24. Russian input source active → paste lands. 25. Terminal "Secure Keyboard Entry" on → `.failed(.secureInput)` at chord-down; password field focused after speaking (hands-free) → "Copied — press ⌘V", `insert_method: clipboard`.
  26. Kleoth History rename field focused → text lands there; History stays key; pill never key.
  27. Start in app A, switch to B mid-utterance → paste lands in B, no focus steal, log records A.
  28. Slack, Chrome, Notes, VS Code, Terminal+vim.
  29. Pill visible while TextEdit is frontmost, caret keeps blinking; over full-screen Safari; across Spaces; no Dock/⌘-Tab entry; closing History still drops to `.accessory`; `panel.level == .statusBar`.
  30. First click registers; drag 1:1, clamps; second display → relaunch → same spot; disconnect → bottom-center of the display under the mouse; Reset pill position animates back; type immediately after a dictation → no dropped characters.
  31. Light/dark legible; Reduce Motion → no animations; VoiceOver announces phases; idle CPU after a 60 s hands-free session.
  32. Dictionary editor → `~/.config/kleoth/dictionary.json` is a plain array; the term transcribes correctly.
  33. History → Dictations: scope picker, day sections, search, detail polished/raw/copy, delete asks + rewrites; Meetings scope unchanged; scope flip doesn't re-trigger the meetings reload; app stays `.regular`.
  34. Stored `google/gemini-3-flash-preview`: (a) summarizing before opening Settings already uses `z-ai/glm-5.3-flash`; (b) open Settings once → picker shows the new default, Keychain rewritten.
  35. At most one Keychain prompt at launch after adding the two keys.

## Current status (2026-08-17 — per-meeting failure surfacing)
- Root-caused "Transcribe in cloud silently reverts": ElevenLabs returned **401 `payment_issue`**
  (failed/incomplete subscription payment on the user's account — fix at elevenlabs.io billing;
  verified with a tiny live Scribe probe). Not an app bug, but the error was invisible: it went
  only to `statusMessage` (popover header), and the detail banner is gated on
  `isProcessingMeeting`, which the failure path clears first.
- ✅ **Per-meeting error surfacing shipped:** `RecordingController.meetingErrors`
  (`[path: message]`, in-memory like `processingPaths`) + `meetingError(for:)` /
  `clearMeetingError(for:)` / private `reportMeetingError(_:in:)` (sets statusMessage AND pins
  the message to the folder). All failure paths wired: stop, runPipeline, both archive-failure
  aborts, runFullTranscription, runOnDeviceTranscription, summarizeLatestMeeting, switchVariant.
  Cleared by `markProcessing` (retry), dismiss, trash, and Remove Transcription. UI: dismissible
  red error card in MeetingDetailView (both processed + unprocessed states, hidden while
  processing) + red "Failed" `KleothPill` on the History row (`.help` = full message);
  `KleothPalette.failureTint` added. 120 tests green; release app reinstalled (relaunch to pick
  up). Not runtime-verified visually.

## Current status (2026-07-22 — transcription-on-demand + 5-item UX pass)
User-requested workflow run (3 workflows: understand/design → implement → fix; 36 agents total,
every review finding adversarially verified). Committed + pushed to main (single commit — the five
features all overlap in RecordingController.swift). 120 core tests green (was 118 → new
Settings/variant/remove tests); both packages build; release app installed to /Applications
(running instance NOT killed — relaunch to pick up). docs/CODE-REVIEW.md stays local/uncommitted.
1. **Auto-transcribe is now OPT-IN (default off, incl. existing installs — CHANGELOG'd):**
   `Settings.autoTranscribe` ← Keychain `auto_transcribe` ("true" strict; absent/other → false);
   Settings → On-device transcription toggle "Transcribe automatically after recording". With auto
   off, `stop()` still does the off-main combine to `meeting.m4a`, then unmarks processing → row
   shows "Untranscribed", status "Recording saved.", NO meta.json written. Untranscribed detail pane
   has prominent **Transcribe** (on-device, `transcribeSaved`) + bordered **Transcribe in cloud**
   (`fullyTranscribe`, disabled w/o ElevenLabs key, no spend dialog — consistent w/ 2026-06-04
   removal). Calendar naming recovered at transcribe time via `recoveredCalendarNaming` (re-queries
   EventKit; only for placeholder titles). StopRecordingIntent/onboarding copy updated.
2. **Playback fix:** `meeting.m4a` is hard-panned stereo (L=mic, R=system) with a historically
   quiet/clipped mic channel — user heard "system only". `AudioPlayerModel` rewritten AVAudioPlayer
   → AVAudioEngine + AVAudioPlayerNode + intermediate mixer with a **1-channel connection = live
   mono downmix** (file untouched — its L/R layout is load-bearing for localtranscribe multichannel
   recovery). Handles `.AVAudioEngineConfigurationChange` (device switch → rebuild graph, reschedule,
   resume), seek clamps to duration−0.05 and never kills playback (EOF is tick()'s job). Also
   `ChannelAudio.normalizeLoudness` gained a ±0.97 vDSP_vclip after the gain stage + maxGain 8→16
   (live probe had shown mic peaks 6.1× full scale hard-clipping) — future recordings get a sane mic
   level; legacy files stay quiet-but-audible via the downmix.
3. **Copy checkmark** reverts after 1.5s (`flashCopied()`, cancel-and-restart task, cancelled on
   reload/disappear).
4. **Per-tier transcript variants:** `MeetingStore.archiveActiveVariant` / `availableVariantTiers` /
   `activateVariant` (pre-validates ALL throwing reads before mutating; promote deletes stale root
   summary when the variant lacks one; re-renders root .md from promoted JSON + current title +
   speakers.json — rename-staleness closed). Detail: tier badge becomes a Menu switcher when >1 tier
   exists; toolbar offers "Fully transcribe"/"Transcribe on device" only when that tier exists
   NOWHERE (active or archived); crash-mid-switch recovery = "Restore <tier> transcript" button on
   the unprocessed pane. Reruns: archive failure ABORTS the run (protects existing transcript);
   stale same-tier archive deleted only AFTER pipeline success; failed rerun auto-restores the
   just-archived variant (no more demote-to-Untranscribed on a network blip).
   `runFullTranscription` now writes the default speakers.json for 2-channel (was a HIGH finding —
   raw speaker_0/1 labels on the new record→cloud path). speakers.json + meta.json stay at root,
   shared across tiers. Known gap: CLI summarize/rename + localtranscribe bypass archiving.
5. **Folder sizes + Remove Transcription:** `RecentMeeting.sizeBytes` via one detached
   enumerator walk, `sizeCache` + `sizingPaths` + `sizeEpoch` generation guard (invalidated in
   delete/remove/unmark/rename/switchVariant); surfaces: History row "5:26 PM · 12m 03s · 214 MB",
   multi-select placeholder "<total> on disk", detail pill, Settings Output footer.
   `MeetingStore.removeTranscription(in:trash:)` trashes the 4 root artifacts + `variants/`, KEEPS
   audio + speakers.json + meta.json (stripped of tier/model/language/cost; title/date/participants
   survive) → row reverts to Untranscribed with real title. History context menu + detail toolbar
   "Remove Transcription" (multi-select, skips processing, no confirmation — trash-recoverable).
   `RecentMeeting.hasMetadata` added; rename gates moved isProcessed→hasMetadata; `isProcessed` now
   keys on transcript.json existence (not meta.json).
- ⚠️ Not runtime-verified (compile-checked + adversarially reviewed only): a live stop with auto
  off, the downmix player by ear (incl. device-switch mid-play), a variant round-trip in the UI,
  sizes on a big ~/Kleoth, Remove Transcription end-to-end. Worth one manual pass.
- Accepted v1 losses (documented in plan/code): participants/consent reset when re-transcribing via
  `transcribeSaved`; untranscribed rows show no duration; single-file Scribe fallback's speaker ids
  keep raw diarization semantics.

## Current status (2026-06-08 — code review + Slack removal)
- ✅ **Whole-project code review** (user-run multi-agent workflow, 72 agents, every finding
  adversarially verified): **verdict = do NOT rewrite** — clean seams (`Transcriber`/`HTTPTransport`),
  correct Swift 6 concurrency, tested core; debt is decomposition + duplication, not rot. 54 findings
  confirmed (2 high, 16 medium, 36 low), 5 refuted. Full report in **`docs/CODE-REVIEW.md`** — kept
  **LOCAL/uncommitted** at the user's request (lists not-yet-fixed items); commit it (or a trimmed
  version) once the rest is addressed.
- ✅ **Applied Tier 1 + both HIGH fixes** (commit `122005b`): summary truncation now retried/surfaced
  (`finish_reason` plumbed through `OpenRouterClient`/`Summarizer`); onboarding "Start" no longer
  dead-ends after Skip; Markdown H1 title sanitized; deterministic diarized You/Them; `LocalizedError`
  for summary errors; single Scribe-price source (`TranscriptTier.usdPerHour`); `renameMeeting` no
  longer fabricates `summary.md`; removed dead `slug` + vestigial `runPipeline(useMultiChannel:)`;
  `shared` is `private(set)`; locale currency. (Slack escaping/SecureField from this commit were then
  superseded by the removal below.)
- ✅ **Slack integration REMOVED entirely** (user: "i don't want slack integration"). Deleted
  `SlackRenderer.swift`, the `kleoth slack` CLI subcommand, `RecordingController.postLatestToSlack` +
  `updateSlackWebhook` + `Command.slackLatest` + `kleoth://slack-latest`, `PostLatestToSlackIntent` +
  its AppShortcut, the Settings Slack section + `Settings.slackWebhook` + `Keychain.Account.slackWebhook`
  + the `SLACK_WEBHOOK`/`slack_webhook` config plumbing, and `integrations/raycast/kleoth-slack-latest.sh`.
  The detail view's "Copy for Slack" became **Copy Summary** (renders the summary as Markdown via
  `MarkdownRenderer`, no transcript). Docs updated (README/CHANGELOG[Unreleased]/Raycast README).
  103 core tests green (3 Slack tests removed); both packages build; release app reinstalled.
- ⚠️ Tier 2/3 from the review still open (app test target, audio resample M4, lazy/off-main detail,
  pipeline-job timeout, Keychain hardening, capture-silence warning, unified re-summarize op,
  decompose `RecordingController`). Not started.

## Current status (2026-06-06 — history management + publish-prep pass)
- ✅ **History sidebar is Finder-like** (user asked: badge visible when selected; ⌘-multi-select +
  delete; double-click rename — researched against Apple docs/HIG first via 3 parallel agents):
  1. **Badges legible on selection:** `KleothPill` + `KleothTierBadge` read
     `@Environment(\.backgroundProminence)` (macOS 14+) and flip to white-on-translucent-white at
     `.increased` — i.e. exactly when the row draws the *focused* accent fill. The gray inactive
     selection stays `.standard` **by design** (tint already legible there — do not "fix").
  2. **Multi-select + delete:** `HistoryView.selection` is now `Set<RecentMeeting.ID>` (⌘/⇧-click
     native). `contextMenu(forSelectionType:menu:primaryAction:)` + `.onDeleteCommand` sit ON the
     List; the menu closure's `ids` set is authoritative (clicked-outside-selection ⇒ just that
     row; empty set on blank-space right-click) — never read `selection` inside it. Context menu:
     Rename (single, processed only) / Show in Finder / Move to Trash. Deletes go through
     `RecordingController.deleteMeetings` → `FileManager.trashItem` (recoverable), **no
     confirmation** per HIG ("avoid alerts for common, undoable actions") — Finder norm; the
     detail view's single-delete keeps its existing dialog. Bulk delete skips processing/active
     -recording dirs ("Skipped — still transcribing."), reloads once. Detail pane shows an
     "N meetings selected" placeholder (combined duration + bulk trash button) when count > 1.
  3. **Double-click inline rename:** `primaryAction` (fires on double-click AND Return — the
     idiomatic List API; `.onTapGesture(count:2)` fights selection) → row's title swaps
     Text→TextField (`.plain`), parent-owned `renamingID`/`renameDraft`, `@FocusState` keyed by
     row id, focus deferred one runloop tick (same-tick focus no-ops), select-all comes free.
     Enter commits (`onSubmit`), Esc cancels (`onExitCommand`), click-away commits (focus
     observer; cancel clears `renamingID` BEFORE focus so the observer can't double-commit).
     Rename allowed only for processed, non-transcribing rows (untranscribed folders have no
     meta.json to hold a title). Core: `MeetingStore.loadMetadata(in:)` +
     `renameMeeting(in:to:)` (rewrites meta.json; re-renders transcript.md/summary.md when a
     transcript exists so the user-owned Markdown header matches; meta-only otherwise) — 3 new
     tests. Controller `renameMeeting` trims/guards + `contentRevision` bump (open detail
     updates live); user titles are durable (`isPlaceholderTitle` gate on summarize).
- ✅ **Publish prep (parallel agent, worktree, merged):** **secret scan of FULL git history =
  CLEAN** (.env/config.json never committed; only masked variable *names* in README/tests — safe
  to make public, no filter-repo needed). Rewrote stale `README.md` (old one described
  Scribe-as-primary/GPT-4.1-mini), added `CHANGELOG.md` (0.1.0, Keep-a-Changelog),
  `docs/RELEASING.md` (documents make-app/make-dmg actual behavior + [Developer Program]-gated
  notarized tier), `packaging/homebrew/kleoth.rb` (draft cask, OWNER/REPO + sha256 placeholders),
  `.gitignore` += `app/.build/`, `*.dmg`; `app/bundle/Info.plist` += `LSApplicationCategoryType`
  (productivity) + `NSHumanReadableCopyright`.
- ✅ **PUBLIC (2026-06-07):** user chose **Apache-2.0** (LICENSE at root; the Raycast extension
  deliberately stays **MIT** — the Raycast Store requires MIT — carve-out documented in README)
  and **repo created + pushed**: `https://github.com/ofcRS/kleoth` (public, `origin` wired,
  topics set, cask placeholders filled with `ofcRS/kleoth`). The repo is LIVE — anything
  committed to main is now world-readable; keep the no-keys discipline absolute.
- ✅ **v0.1.0 RELEASED (2026-06-07, user-requested parallel workflow — 6 agents, every leg
  adversarially verified):** https://github.com/ofcRS/kleoth/releases/tag/v0.1.0 — DMG +
  `.sha256` assets live (curl 200; GitHub's server-side digest matches `6028cafb…`). The stale
  local v0.1.0 tag (was at 7df4d21) was re-created annotated at origin/main and pushed. README
  now opens with a generated hero banner, release/downloads badges, and a direct-download link;
  cask `sha256` filled with the real digest.
- ✅ **Brand images generated headlessly** (`app/branding-src/readme-images/generate.swift` —
  AppKit offscreen render @2x → sips downscale): `docs/assets/hero.png` (1600×420, wired into
  README) + `docs/assets/social-preview.png` (1280×640). ⚠️ Gotcha: the iconset PNG has NO
  alpha — white-baked corner gaps + ~2.64% white padding on the 1024 canvas — so the script
  clips the icon to an inset rounded tile (inset 2.84%, radius 26% — measured by pixel probe)
  and draws the shadow from an opaque rounded base first (a shadow set inside the clip gets
  clipped away with the corners). First render had a white halo; fixed + visually re-verified.
- ✅ **Demo meetings staged for screenshots:** `~/Kleoth/meeting-2026-06-07-{091200,103000,
  130000,154500}` — invented EN business content, mixed Cloud/On-device tiers, durations via
  `cost.audio_duration_secs`, deliberately NO `.m4a` (detail view gates its player on audio
  presence, so nothing breaks; list duration falls back to the stored value). All four pass
  `kleoth render`. Remove after screenshots: ⌘-select all four in History → Move to Trash.
- ✅ **README screenshots (2 of 3, 2026-06-08):** user captured the popover + History-detail
  windows (on the staged demo data — the detail shot also confirms the selected-row Cloud badge
  fix renders white, live). Framed both on the hero gradient via
  `app/branding-src/readme-images/frame-shot.swift` (transparent-surround window shots →
  `docs/assets/screenshot-{detail,popover}.png`) and wired into the Screenshots section. Minor:
  the popover capture has faint terminal bleed-through in its translucent header (macOS vibrancy;
  acceptable — recapture against a clean desktop only if it bugs anyone).
- ⏳ **Publish leftovers:** (1) onboarding screenshot still TODO (Settings → Show Welcome Window);
  (2) upload `docs/assets/social-preview.png` manually: GitHub repo Settings → Social preview
  (no API/CLI exists for it); (3) demo meetings still in `~/Kleoth` — delete the four
  `meeting-2026-06-07-*` folders when done shooting; (4) stale `BUILD-APP.md` (references
  `KleothApp` binary; now `Kleoth`) — update or fold into docs/RELEASING.md; (5) Developer
  Program → notarized tier + Homebrew tap (cask draft ready at packaging/homebrew/kleoth.rb).
- ✅ Both packages build; **100 core tests green** (was 97); release app reinstalled; DMG rebuilt.
- ⚠️ Not runtime-verified: the new History interactions visually (multi-select, inline-rename
  focus/commit behavior, badge treatment on selection) — all compile-checked + research-backed.

## Current status (2026-06-05 — background processing pass)
- ✅ **All prior work merged to `main`** (fast-forward from `fix/scribe-attribution-and-summary-language`
  at `22fe200`); development now happens on `main`.
- ✅ **Stop is non-blocking** (user: "when recording is over, i want it to be moved into the list
  below, and start recording button to be unlocked immediately"). `stop()` frees the capture slot
  up front (recorder/dir/startedAt captured into locals, controller state cleared), marks the
  folder as processing, and returns after queueing — the record button is gated ONLY on consent
  now, so a new recording can start while the previous one transcribes.
- ✅ **Serial pipeline queue:** `enqueuePipelineJob` chains jobs on `pipelineQueueTail` (strict
  FIFO). Rationale: every `LocalTranscriber.transcribe` builds its own ~600 MB WhisperKit, so
  concurrent runs would double memory + fight over the ANE. `stop()`, `transcribeSaved`,
  `transcribeExistingFile` (now pre-creates its meeting dir via `makeSessionDirectory`), and
  `fullyTranscribe` (split into guard+enqueue and `runFullTranscription` worker) all queue;
  multiple meetings can be queued back-to-back and run one at a time.
- ✅ **In-flight meetings live in the list:** `processingDir: URL?` → `@Published
  processingPaths: Set<String>` (standardized paths; `markProcessing`/`unmarkProcessing` reload the
  list; `isProcessing` is now derived + `private(set)`). `loadRecentMeetings` no longer hides the
  mid-pipeline folder — it lists it (`RecentMeeting.isTranscribing`) with a spinner +
  "Transcribing…" in the popover row, History sidebar row, and a dedicated detail-view state;
  only the *active recording* folder stays hidden (files still being written; that branch never
  probes duration, so listing during the off-main combine is safe). Failure paths unmark → row
  resurfaces as "Untranscribed". `processingPaths` is in-memory only: quit mid-run → folder shows
  as "Untranscribed" on relaunch (self-healing).
- ✅ **Per-meeting gating instead of global:** detail's "Fully transcribe" + progress banner key on
  `isProcessingMeeting(dir)`, so other meetings processing in the background don't block/banner
  this one. Double-queueing the same dir is guarded everywhere. Popover header subtitle shows
  "Transcribing in the background"; the top status line is reserved for transient messages
  ("Finalizing recording…", "Saved …", errors) and hides at "Idle" — pipeline progress lives on
  the row spinner. Quit while processing now asks (confirmationDialog) — audio survives either way.
- ✅ `stop()` returns a `String` outcome (`@discardableResult`) — "Recording saved — transcribing
  in the background." — used by `StopRecordingIntent`'s dialog (statusMessage may already be
  reset/overwritten by then).
- ✅ Both packages build; 97 core tests green; release app installed; DMG rebuilt (7.8M, SHA-256
  `681e4aba…`). ⚠️ Not runtime-verified: a live stop→record-again overlap and the queue under
  real long meetings (logic compile-checked only; WhisperKit serialization is by construction).

## Current status (2026-06-04 — onboarding/raycast/polish pass)
- ✅ **First-run onboarding** (user: "it should be experience… ready? start recording"). Researched
  via a 4-agent workflow (Transcribe-Anything-style name question; menu-bar-app welcome-window
  norms; permission priming; the openWindow/TabView(.page)/TCC traps), then implemented:
  `Views/OnboardingView.swift` — fixed 560×600 five-step machine (Welcome → Name → Permissions →
  Model+Language → "Ready? Start recording."), `Window(id: "kleoth-onboarding")` scene, launch
  trigger = `.task` on the **MenuBarExtra label** (the only view mounted at launch with a live
  SwiftUI env; `openWindow` is unusable from App.init/AppDelegate). Gating:
  `needsOnboarding = onboarding_completed != "true" && !consentAcknowledged` (existing installs
  never see it); closing the window mid-flow counts as done (idempotent `finalize()`).
  The NAME step seeds `speaker_0` (default map becomes `{speaker_0: <name|You>, speaker_1: Them}`),
  prefilled from `NSFullUserName()`. Permissions step primes consent + mic
  (`AVCaptureDevice.requestAccess`) + system audio (`SystemAudioTap.primePermission()` — creates &
  destroys a throwaway tap; macOS has NO query/request API for it). Replayable via Settings →
  "Show Welcome Window".
- ✅ **Welcome jingle + animation:** chime = **ElevenLabs sound-generation**, chosen BY EAR across
  three batches (12 candidates): the first harp-glissando prompts came out cinematic-eerie ("so
  scary"), notification-style timbres (marimba/music box/kalimba/celesta/felt piano) landed felt
  piano, and a third batch added the user's requested extra note. Bundled
  `Resources/WelcomeChime.m4a` = `chime3-feltpiano-3chords` (three warm felt-piano chords rising,
  2.4s). All candidates + prompts + the offline Karplus-Strong fallback (`synth-chime.m4a`) + swap
  instructions live in `app/branding-src/jingle/NOTES.md`. Played once on onboarding appear
  (fail-silent if missing). Welcome step: spring-in lyre mark + staggered text reveals, gated on
  Reduce Motion. **Prompt lesson:** for app chimes, ask the SFX model for notification language
  ("soft felt piano… clean and dry", prompt_influence 0.6), never "glissando/reverb tail".
  The key fix also unblocked `/v1/user/subscription` → Settings → Usage reports ElevenLabs live
  (verified: payg tier, credits populate). `afplay` from the agent shell plays through the user's
  speakers — useful for letting them audition candidates.
- ✅ **Raycast extension** (`integrations/raycast-extension/` — TypeScript, @raycast/api): Toggle/
  Start/Stop Recording (kleoth:// URLs), Search Meetings (reads ~/Kleoth, open/copy summary &
  transcript + paths), Latest Summary (markdown Detail). Validated with `ray build`; registered in
  Raycast via a one-shot `ray develop`. Re-import: `npm run dev` in that dir. Gotcha:
  `@types/react` must be ^19 with current @raycast/api. The old script commands in
  `integrations/raycast/` remain.
- ✅ Smaller asks: Russian moved to the END of the Settings language list (+footer de-Russified;
  user-facing copy mentions no language); the "Fully transcribe" price-confirmation dialog REMOVED
  (button transcribes immediately; `MeetingFormat.usd` deleted — the Usage section is now the only
  money surface anywhere); detail toolbar's copy button is now a menu: Copy for Slack / Copy
  Transcript Path / Copy Summary Path.
- ⚠️ Orchestration note: the implementation workflow's final review agent stalled (3-min
  no-progress watchdog ×6) and the run was marked failed — but Create+Build phases had already
  landed everything (both packages compiled, 97 tests green); the review was redone by hand.
- ⚠️ Not runtime-verified: the onboarding window visually (it only auto-opens on a fresh install;
  use Settings → Show Welcome Window or the from-scratch DMG test), the chime audibly, and the
  Raycast commands end-to-end.

## Current status (2026-06-04 — summary/wording/usage pass)
- ✅ **Rename now reaches the summary.** `SpeakerMapper.apply(_:toSummary:previousTranscript:)`
  rewrites action-item owners + highlight speaker names on rename (exact-match on the previous
  display name or bare id; free prose untouched). Wired in `RecordingController.rename` AND the
  CLI `kleoth rename`; the rewritten summary.json + `contentRevision` bump means the open detail
  view updates immediately. (Bug: rename only rewrote the transcript; summary kept old names
  forever.) Unit-tested incl. consecutive renames.
- ✅ **Summary restructured** (see "Summary shape" above) — user: "too many slop categories".
- ✅ **Money de-emphasized:** removed the popover Session-cost line, per-row $ in popover/History,
  the detail cost tiles, and $ amounts in status messages. `RecentMeeting.costUSD` +
  `currentCostUSD` deleted. Costs still land in meta.json. The ONE remaining $ surface besides
  Settings → Usage is the "Fully transcribe" **spend-confirmation** dialog (~$0.22/hr estimate) —
  deliberate: it's a payment consent gate.
- ✅ **Settings → Usage section** (the only money/quota surface): live provider-reported numbers via
  new `Sources/KleothCore/Usage/ProviderUsage.swift` — `ElevenLabsUsageClient`
  (`GET /v1/user/subscription`, `xi-api-key`; credits used/limit + cycle reset) and
  `OpenRouterUsageClient` (`GET /api/v1/credits`, Bearer; lifetime purchased/used → remaining).
  Fail-soft per provider, refresh button, keys only ever in headers. 5 unit tests on MockTransport.
- ✅ **Wording:** tier badges now "On-device" / "Cloud" everywhere user-facing.
- ✅ **Keychain prompts (5–6 per launch) fixed structurally:** `Keychain` now stores ALL values in
  ONE consolidated item (service `dev.kleoth`, account `settings`, JSON dict) read once per launch
  into an in-memory cache → at most ONE permission prompt ever (the app used to read 6 separate
  items at startup → 6 prompts on any ACL/signature mismatch, recurring if the user clicked
  "Allow" instead of "Always Allow"). Legacy per-value items migrate on first load and are deleted
  only after a successful read — a denied prompt never destroys a key, and a denied *blob* read
  throws rather than falling into migration (which would re-burst) or clobbering on a later write.
  Call sites unchanged (same `Keychain.get/set` API). Tell the user: click **Always Allow**.
- ⚠️ **ElevenLabs usage needs a key scope:** the account's current API key is STT-scoped;
  `GET /v1/user/subscription` returns **401** (verified live) → the Usage row shows an actionable
  hint ("needs the “User” read permission"). OpenRouter `GET /api/v1/credits` verified live
  (`total_credits` 25, decodes into `OpenRouterCredits`).
- ✅ 97 core tests green; both packages build clean; release installed + running.
- ⚠️ Not runtime-verified: the Usage section against the live APIs, and a live rename round-trip in
  the app UI (the remap itself is unit-tested; controller flow compile-checked).
- Note: old names inside free prose (tldr/overview text) survive a rename by design — only the
  structured name fields are rewritten; a re-summarize regenerates prose with new names.

## Current status (2026-06-03 — 7-fix UX pass)
- ✅ Both packages build clean; **86 core tests green**; release app installed + running.
- ✅ **Seven fixes shipped (multi-agent reviewed, then triaged):**
  1. **Popover header icon** → the lyre. First pass used a full-color `AppMark.png` chip; the user
     found it too heavy ("minimalistic was better"), so it's now (2026-06-04) the **menu-bar
     template glyph** (`KleothAssets.menuBarGlyph()`) accent-tinted on a quiet accent-washed tile
     (SF Symbol fallback). `appMark()` + `AppMark.png` were removed as dead. Popover bottom padding
     bumped to `spacingXL` (24) — the window's corner radius curved into the footer at uniform 16.
  2. **Mic-vs-system loudness** → `ChannelAudio.normalizeLoudness` (per-channel RMS via vDSP) applied
     before the Scribe mono-mix (`mixToMono`) and the playback combine (`Recorder.combine`). ffmpeg
     is NOT installed → native AVFoundation/Accelerate instead. Attribution is unaffected (it reads
     raw per-channel envelopes, not the normalized mix).
  3. **Empty-state art** regenerated via OpenRouter (`jobs-empty3.json`, image-to-image off `icon-a`)
     — polished full-bleed lyre tiles, no squiggle/vignette. In `Resources/Empty*.png` (600px).
  4. **Local RU→EN bug** fixed (see WhisperKit specifics) + Settings **Language** picker.
  5. **History as a ⌘-Tab window** → `AppActivation` flips `.accessory`↔`.regular` while a titled
     window (History/Settings) is open; down-transition recomputed from the live window list
     (self-healing, handles concurrent windows). Wired from History + Settings `onAppear/onDisappear`.
  6. **SOTA progress bar** → `ScribeOptions.onUploadProgress` → `HTTPTransport.upload(…progress:)`
     (URLSession per-task delegate) → `RecordingController.transcriptionProgress` (@Published) →
     determinate bar (upload) + indeterminate (server-side) in popover + detail.
  7. **30s freeze on stop** fixed → `recorder.stop()` **and** the 2-channel combine now run off the
     main actor (`Task.detached`, `nonisolated(unsafe)` capture; `Recorder.combineChannels` static).
     Dir-watcher reloads debounced (`scheduleReload`, 0.3s); durations cached (`durationCache`);
     in-progress folder excluded via `activeRecordingDir`/`processingDir` (no flash / no partial-file
     duration probe).
- ✅ **Verified live:** local WhisperKit RU meeting → `language_code: ru`, Cyrillic transcript, correct
  You/Them (ran `localtranscribe` on a /tmp copy; originals untouched).
- ⚠️ **Not runtime-verified this pass:** the freeze timing under a real long record→stop, the SOTA
  upload progress against the live API, and the ⌘-Tab behavior visually (no Screen-Recording perm to
  screenshot). All build clean and the app launches/runs stable.

## Current status (2026-06-01)
- ✅ Both packages build clean; **68 tests green** (was 51).
- ✅ **Four fixes shipped + verified live** (re-summarized a copy of `meeting-2026-05-31-234904`,
  gemini-3-flash-preview, structured JSON-schema): (1) wall-clock duration from the file (showed
  764.8s, not the stored 2× 1529.7s); (2) generated title; (3) `speakers.json` applied on load
  (You/Them); (4) native SwiftUI summary/detail UI (no more raw-markdown blob).
- ✅ **Scribe mono-attribution path** A/B-validated live: mono mixdown = −50% cost + correct
  duration, channel-energy attribution keeps reliable You/Them. Used by the app's "Fully
  transcribe" and `localtranscribe … scribe`.
- ⚠️ **Still not runtime-verified:** the WhisperKit **local** record→transcribe path; the native UI
  visually; and the integrated `ChannelAttributedScribeTranscriber` against the live API (its
  `mixToMono` matches the A/B-validated mixer and compiles; the raw mono Scribe call was validated
  manually). Verify local via `localtranscribe <dir>` (no `scribe`) or record→stop in the app.

## Known issues / open threads
- ✅ **FIXED (2026-06-01) — speaker map applied on load.** `MeetingStore.loadTranscript` now applies
  `speakers.json` at the single chokepoint, so You/Them survive re-summarize / redisplay / render /
  Slack and seed the rename sheet. (Was: names only applied in `MeetingPipeline.run` / rename.)
- ✅ **FIXED (2026-06-01) — per-engine transcription cost.** CLI `summarizeExistingMeeting` bills $0
  for local (and unknown/`nil`) tiers, $0.22/hr only for `sota-scribe`, with duration probed from
  the audio file via `AudioProbe`.
- **Minor leftovers (low):** the new `ChannelAudio` DSP (`mixToMono`/`envelope`) has no pure unit
  test (lives in the app package, which has no test target; `ChannelAttribution` IS tested and the
  mix was A/B-validated); and `RecordingController.runPipeline(useMultiChannel:)` (ex-`process`)
  still carries a vestigial unused param.
- App Intents don't auto-surface in Shortcuts/Spotlight: SwiftPM build doesn't run
  `appintentsmetadataprocessor` (needs Swift const-extraction Xcode does). URL scheme + hotkey +
  Raycast work without it. Documented in `KleothIntents.swift`.
- First-run model download UX is just the popover progress line; consider a clearer affordance.
- ✅ **DONE (2026-06-03) — transcription-language setting** (Auto + pin `ru`/`en`/… ) in Settings.
- Still not built: model-size picker; a default-engine Settings toggle (local vs Scribe). The
  `localtranscribe` tool builds `LocalTranscriber` with no language pin (auto path) — fine now.
- SOTA progress is upload-only (Scribe is one POST with no server-side progress) → determinate during
  upload, then indeterminate while it transcribes. Local (WhisperKit) has a `TranscriptionCallback`
  if a local progress bar is ever wanted (not wired).

## Follow-ups from research
- **Distribution (DMG pipeline DONE 2026-06-04 — `app/make-dmg.sh`):** builds, signs, and packages
  `Kleoth-<version>.dmg` (staging with /Applications symlink + Read Me + volume icon; UDRW→UDZO;
  DMG itself signed; `hdiutil verify` + SHA-256 printed). Two tiers: default self-signed (installs
  on this Mac; elsewhere right-click → Open), and a wired-but-unused public tier —
  `KLEOTH_SIGN_IDENTITY` (Developer ID → hardened runtime + timestamp re-sign) +
  `KLEOTH_NOTARY_PROFILE` (notarytool submit --wait + staple). **Still needed for the
  Gatekeeper-clean tier:** Apple Developer Program membership ($99/yr) for the Developer ID cert
  + notarization; Sparkle auto-update later. (LICENSE/README/CHANGELOG/RELEASING done 2026-06-06/07;
  repo public at github.com/ofcRS/kleoth.) PKG rejected (enterprise/MDM only).
- **Branding:** macOS 26 layered `.icon` via Icon Composer → compile with `actool` inside
  `make-app.sh` (no Xcode project) → set `CFBundleIconName` (Tahoe) + `CFBundleIconFile`
  (legacy). AI for concept, finalize as vector. Theme: Greek *kleos* "that which is heard".

## Conventions / gotchas
- **snake_case round-trip:** `MeetingStore` encodes/decodes with `convert{To,From}SnakeCase`.
  All-caps acronym suffixes do NOT round-trip (`transcriptionUSD` → `transcription_usd` →
  decodes to `transcriptionUsd` ✗). `CostBreakdown` uses explicit CodingKeys
  (`transcription_cost`/`summary_cost`). **Any new stored key must be acronym-free** (e.g.
  `transcript_tier`).
- **`Transcriber: Sendable`:** a type's conformance must be declared in the same file as the
  type (so `ScribeClient: Transcriber` lives in `ScribeClient.swift`, not a separate extension).
- **`vDSP_measqv` = MEAN of squares** (not sum) → `sqrt(measqv)` IS the correct RMS in
  `ChannelAudio.normalizeLoudness`/`envelope`. (`vDSP_svesq` is the sum-of-squares one.) A reviewer
  flagged this as a "divide-by-N missing" bug — it's a false positive; do not "fix" it.
- **Off-main capture audio work:** decode/re-encode (`Recorder.combine`, `ChannelAudio.mixToMono`)
  is seconds of CPU for a long meeting — never run it on `@MainActor`. `Recorder.combineChannels`
  is a pure static over `Sendable` URLs for exactly this; `stop()`+combine run in `Task.detached`.
- **SwiftPM exe quirk:** `swift build --target <exe>` compiles the module but does NOT link a
  runnable binary; use `swift build --product <exe>` to get `app/.build/debug/<exe>`.
- **Availability:** `Recorder`/`SystemAudioTap` are `@available(macOS 14.4, *)`; WhisperKit runs
  on 14.4+. `RecordingController` is unconditionally available and boxes `Recorder` as `AnyObject`.
- **Recovery surfacing:** `loadRecentMeetings` lists audio-only folders (no `meta.json`) as
  `isProcessed=false` ("Untranscribed"), excluding the in-progress recording dir. `~/Kleoth/dictations/`
  never shows as a meeting (no audio inside).
- **Dictation keys/paths (2026-09-03):** Keychain `dictation_enabled` / `dictation_model` (NOT in
  `Keychain.legacyAccounts`); `~/Kleoth/dictations/<day>.json`; `~/.config/kleoth/dictionary.json`;
  UserDefaults `dev.kleoth.dictation.pillPlacement`; `$TMPDIR/kleoth-dictation/`. Every stored
  property is acronym-free (`appBundleId`, `displayId`) — the snake_case rule above applies.
- **Un-sandboxed is load-bearing:** `TextInserter` posts `CGEvent`s to `.cgSessionEventTap`, which
  the App Sandbox blocks outright. Never add `com.apple.security.app-sandbox` to
  `app/bundle/Kleoth.entitlements`. Accessibility trust is bound to the code signature → always
  sign with the stable "Kleoth Self-Signed" identity (`app/setup-signing.sh`).
- **`AppDelegate` ↔ `@MainActor` controllers:** delegate callbacks run on the main thread; use
  `MainActor.assumeIsolated { … }`, never `Task { @MainActor in … }` — in `applicationWillTerminate`
  the process can exit before the hop runs.

## Security (hard rules)
- **API keys NEVER printed to stdout or committed.** `.env` (ELEVEN_API_KEY, OPENROUTER_API_KEY)
  and `config.json` are gitignored. Keys live in `~/.config/kleoth/config.json` (chmod 600) and
  repo `.env`. When inspecting `.env`, show variable NAMES only (`cut -d= -f1`).
- Live API probing is fine but read the key into a shell var and only ever put it in a curl
  header — never echo it; OpenRouter/ElevenLabs response bodies don't contain the key.
- Keychain items are bound to the app's code signature (service `dev.kleoth`); re-signing can
  trigger a one-time re-auth prompt. Stable self-signed cert = "Kleoth Self-Signed".
- Skills (`transcribe-meeting`, `summarize-meeting`) state: never read or echo `.env` or any keys.
