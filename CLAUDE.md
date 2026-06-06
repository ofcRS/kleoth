# Kleoth — project context & state

Local-first, bot-free macOS meeting recorder (open-source tl;dv / Fireflies alternative).
Captures system audio + mic locally → transcribes → summarizes → writes Markdown/JSON the
user owns. Native Swift 6 / SwiftUI menu-bar app + a `kleoth` CLI.

_Last updated: 2026-06-06. This file is living context for future sessions — keep it current._

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
- **Summary shape (lean since 2026-06-04):** `MeetingSummary` = `title?`, `tldr`, **`overview?`**
  (detailed multi-paragraph prose — the "Summary" section), `action_items`,
  `per_speaker_highlights`. The old decisions / key_points / open_questions / suggested_tags were
  removed as slop at the user's request; legacy summary.json files still decode (extra keys
  ignored, `overview` nil → section omitted, arrays lenient-default to `[]`). Reading order
  everywhere (app view, summary.md): TL;DR → Summary → Action Items → Per-Speaker Highlights →
  Transcript. `maxOutputTokens` 8192. Slack render = title + TL;DR + top-3 action items.

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
(always). One meeting = one folder. Folder name encodes start time.

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
- ⏳ **User decisions pending for publish:** (1) LICENSE — not created; agent recommends
  **Apache-2.0** (old README said "intended Apache-2.0"; Raycast extension declares MIT — align);
  (2) GitHub repo name/owner (`gh` authed as `ofcRS`, **no git remote configured yet**) → then
  fill OWNER/REPO in the cask; (3) stale `BUILD-APP.md` (references `KleothApp` binary; now
  `Kleoth`) — update or fold into docs/RELEASING.md; (4) three `<!-- TODO: screenshot -->`
  placeholders in README.
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
  `KLEOTH_NOTARY_PROFILE` (notarytool submit --wait + staple). **Still needed for true public
  release:** Apple Developer Program membership ($99/yr) for the Developer ID cert + notarization;
  LICENSE (decision pending — README/CHANGELOG/RELEASING done 2026-06-06); Sparkle auto-update
  later. PKG rejected (enterprise/MDM only).
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
