# Kleoth — project context & state

Local-first, bot-free macOS meeting recorder (open-source tl;dv / Fireflies alternative).
Captures system audio + mic locally → transcribes → summarizes → writes Markdown/JSON the
user owns. Native Swift 6 / SwiftUI menu-bar app + a `kleoth` CLI.

_Last updated: 2026-06-03. This file is living context for future sessions — keep it current._

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
- `kleoth` (exe): subcommands `transcribe`, `summarize`, `rename`, `render`, `slack`.
- `KleothCoreTests` (51 tests, all green).

**Package 2 (`app/`)** — `platforms: [.macOS("14.4")]`, deps: `..` (KleothCore),
`sindresorhus/KeyboardShortcuts`, `argmaxinc/argmax-oss-swift` (WhisperKit @ 0.18.0).
- `KleothCapture` (lib): Recorder (writes `mic.m4a` + `system.m4a`, builds 2-channel
  `meeting.m4a`), MicCapture, SystemAudioTap (Core Audio process tap), ScreenshotCapture,
  **LocalTranscriber** (WhisperKit).
- `KleothApp` (exe): MenuBarExtra agent, `RecordingController` (`@MainActor`, owns capture +
  pipeline, app-lifetime `shared`), Views (MenuView, HistoryView, MeetingDetailView, Settings,
  Consent, SpeakerRename), App Intents, `kleoth://` URL scheme, global hotkey.
- `taptest` (exe): dev probe for the audio tap.
- `localtranscribe` (exe): headless recovery tool — re-transcribe a meeting folder with the
  same engine the app uses. `localtranscribe <meeting-dir> [scribe]`.

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
  `.sotaScribe` (`"sota-scribe"`). Badges in History + Detail.
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

## Summarization
- OpenRouter chat-completions. **Default model: `google/gemini-3-flash-preview`** (set in
  `Settings.swift` and in the Keychain `default_model`). Was `openai/gpt-4.1-mini` — broken (see below).
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

### ⚠️ OpenRouter data-policy constraint (important, account-specific)
This account's privacy setting blocks providers that may train on data. Combined with
`require_parameters: true`, that **404s** (`"No endpoints available matching your guardrail
restrictions and data policy"`) for `openai/*`, `mistralai/*`, `qwen/qwen3.x-max`, `x-ai/grok-*`.
- **Works (no-train providers, verified live):** `google/*` (Gemini 3.x), `deepseek/*` (v4),
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

# Recovery / headless transcribe (NOTE: --product, not --target — see gotchas)
swift build --package-path app --product localtranscribe
app/.build/debug/localtranscribe <meeting-dir> [scribe]
```

## Meeting folder layout (`~/Kleoth/meeting-yyyy-MM-dd-HHmmss/`)
`mic.m4a`, `system.m4a`, `meeting.m4a` (2-channel combined) · `transcript.json` (raw Scribe or
synthesized) · `transcript.md` · `summary.json` · `summary.md` · `speakers.json` · `meta.json`
(always). One meeting = one folder. Folder name encodes start time.

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
  mix was A/B-validated); and `RecordingController.process(useMultiChannel:)` is now a vestigial
  unused param.
- App Intents don't auto-surface in Shortcuts/Spotlight: SwiftPM build doesn't run
  `appintentsmetadataprocessor` (needs Swift const-extraction Xcode does). URL scheme + hotkey +
  Raycast work without it. Documented in `KleothIntents.swift`.
- First-run model download UX is just the popover progress line; consider a clearer affordance.
- Optional features offered, not built: transcription-language setting (pin `ru`) + model-size
  picker; a default-engine Settings toggle (local vs Scribe).

## Follow-ups from research (not started)
- **Distribution:** app is self-signed (Gatekeeper-blocked elsewhere). For release: Apple
  Developer Program + Developer ID Application cert → hardened runtime → notarize (`notarytool`)
  → staple → ship a **DMG** + **Sparkle** auto-update. PKG only if enterprise/MDM. Scriptable;
  no Xcode project required.
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
- **SwiftPM exe quirk:** `swift build --target <exe>` compiles the module but does NOT link a
  runnable binary; use `swift build --product <exe>` to get `app/.build/debug/<exe>`.
- **Availability:** `Recorder`/`SystemAudioTap` are `@available(macOS 14.4, *)`; WhisperKit runs
  on 14.4+. `RecordingController` is unconditionally available and boxes `Recorder` as `AnyObject`.
- **Recovery surfacing:** `loadRecentMeetings` lists audio-only folders (no `meta.json`) as
  `isProcessed=false` ("Untranscribed"), excluding the in-progress recording dir.

## Security (hard rules)
- **API keys NEVER printed to stdout or committed.** `.env` (ELEVEN_API_KEY, OPENROUTER_API_KEY)
  and `config.json` are gitignored. Keys live in `~/.config/kleoth/config.json` (chmod 600) and
  repo `.env`. When inspecting `.env`, show variable NAMES only (`cut -d= -f1`).
- Live API probing is fine but read the key into a shell var and only ever put it in a curl
  header — never echo it; OpenRouter/ElevenLabs response bodies don't contain the key.
- Keychain items are bound to the app's code signature (service `dev.kleoth`); re-signing can
  trigger a one-time re-auth prompt. Stable self-signed cert = "Kleoth Self-Signed".
- Skills (`transcribe-meeting`, `summarize-meeting`) state: never read or echo `.env` or any keys.
