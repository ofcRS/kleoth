# Kleoth

Local-first macOS voice & capture app: dictation, bot-free meeting recording, screen recording. Native Swift 6 /
SwiftUI menu-bar app and a `kleoth` CLI. Captures mic + system audio locally → transcribes →
summarizes → writes Markdown/JSON the user owns. Public repo: github.com/ofcRS/kleoth (Apache-2.0).

Keep this file short: commands, architecture, decisions, gotchas. Session narrative goes in
`docs/SESSION-LOG.md` (archived history) or the design docs under `docs/plans/`, never here.

## Environment
macOS 26 (Tahoe), Apple Silicon, Swift 6.3, Xcode 26. Floors: KleothCore/CLI = macOS 13; app = 14.4.
Liquid Glass gated behind `if #available(macOS 26, *)`.

## Commands
```bash
swift build && swift test                        # core + CLI (490 tests)
swift build --package-path app                   # app package
bash app/setup-signing.sh                        # once: "Kleoth Self-Signed" cert (Accessibility/TCC trust binds to it)
bash app/make-app.sh release                     # bundle + sign + install /Applications/Kleoth.app
pkill -x Kleoth; open -a Kleoth                  # relaunch (make-app does NOT kill the running instance)
pkill -x Kleoth; open -a Kleoth --args -KleothSimulateFirstRun YES   # first-run flows again, this launch only
bash app/make-dmg.sh                             # app/dist/Kleoth-<version>.dmg (version = app/bundle/Info.plist)
swift run kleoth summarize <dir> --model <slug> --provider claude-code|codex|local|openrouter  # re-summarize in place

# Headless probes (use --product, not --target — --target links no binary)
swift build --package-path app --product localtranscribe && app/.build/debug/localtranscribe <meeting-dir> [scribe]
swift build --package-path app --product dictate && app/.build/debug/dictate 4 [--no-polish] [--device <uid>] [--provider claude-code|codex|local|openrouter] [--text "<raw>" --runs N]
app/.build/debug/dictate --file <audio> [--fail-first N] [--keep-on-failure]   # real clip through the Scribe retry policy; N injected transient failures; keep → a REAL pending History row
swift build --package-path app --product screenrec && app/.build/debug/screenrec 10 [--inspect f.mp4] [--extract f.mp4] [--words f.m4a]
swift run --package-path app pillsandbox                                # pill playground
app/.build/debug/pillsandbox --film <dir> --edge right --sequence idle,armed,listening,done,idle   # filmstrip PNGs
bun ~/.claude/skills/gpt-images/scripts/gpt-images.ts app/branding-src/<set>/jobs.json           # brand imagery (brief: app/branding-src/BRAND.md)
bun marketing/sync.ts check [--offline] | apply [--no-remote]   # public pitch: drift report / rewrite README hero, cask, Raycast, images, GitHub About+topics
bun test ./marketing/sync.test.ts                              # release-gate command parser
```
Logs: `/usr/bin/log stream --predicate 'subsystem == "dev.kleoth"'` (categories `Dictation`,
`DictationHotkey`, `PillTrace` — the latter needs `defaults write dev.kleoth.app KleothPillTrace -bool YES`).
Crash reports: `~/Library/Logs/DiagnosticReports/Kleoth-*.ips`. Reset TCC: `tccutil reset ScreenCapture|Accessibility dev.kleoth.app`.

## Architecture — two SwiftPM packages
**Root package** (macOS 13, dep: swift-argument-parser)
- `KleothCore`: Models, `HTTPTransport` seam, `Transcription/` (`Transcriber` protocol, `ScribeClient`,
  normalizer), `Summarization/` (`OpenRouterClient`, `Summarizer`, `ModelCatalog`), Rendering,
  SpeakerMapping, `Storage/MeetingStore`, `Config/` (Settings, Credentials, Keychain), `Pipeline/`,
  `Dictation/` (chord machine, polisher, log store, `PillGeometry`, `PolishGate`,
  `DictationTranscription` = Scribe budget + retry policy, `DictationAudioStore` = kept clips), `ScreenRecording/`
  (defaults, geometry, session machine, audio math, `Record`/`Store` transcript sidecar), `Usage/`,
  `Concurrency/` (`withTimeout`, `withDeadline`).
- `kleoth` CLI: `transcribe`, `summarize`, `rename`, `render`. `KleothCoreTests`.

**`app/` package** (macOS 14.4; deps: `..` as `.package(name: "kleoth-app", path: "..")`,
KeyboardShortcuts, WhisperKit 0.18)
- `KleothCapture`: `Recorder` (mic.m4a + system.m4a → 2-channel meeting.m4a), `MicCapture`,
  `SystemAudioTap` (Core Audio process tap), `LocalTranscriber` (WhisperKit), `DictationCapture`,
  `InputDevices`, `AudioFormat` (AAC bit-rate clamp, `TapWriter`), `ObjCExceptions`,
  `ScreenRecording/` (`ScreenRecorder` + sources/sink/mix pump/frame gate/`MovieWriter`).
- `KleothObjC`: `KLCatchObjCException`.
- `KleothPillUI`: the pill (`DictationPanel`, `DictationPillController`, model, view, `PillMenu`,
  `PillTypes` = the contract). Shared by the app and `pillsandbox`.
- `KleothApp`: `MenuBarExtra` agent; `RecordingController` (meetings + serial pipeline queue),
  `DictationController`, `ScreenRecordingController`, `PillCoordinator` (single face in front of the
  pill), `AppConfig` (Settings + Keychain overlay), `Views/` (MenuView, HistoryView with
  Meetings | Dictations | Recordings scopes, SettingsView = flat `HStack` sidebar over `SettingsPage`,
  Onboarding, recordings viewer), App Intents, `kleoth://` URL scheme. No test target.
- Executables: `taptest`, `localtranscribe`, `dictate`, `screenrec`, `pillsandbox`.

Design docs (binding contracts, error matrices, manual checklists): `docs/plans/2026-09-03-dictation.md`,
`docs/plans/2026-09-06-screen-recording.md`, `docs/plans/2026-09-07-recordings-viewer.md`,
`docs/plans/2026-09-23-dictation-retry.md`, `docs/plans/2026-09-24-summary-truncation-and-onboarding-skip.md`,
`docs/plans/2026-09-24-positioning.md`.

## Data on disk
- Meeting = `~/Kleoth/meeting-yyyy-MM-dd-HHmmss/`: `mic.m4a`, `system.m4a`, `meeting.m4a`,
  `transcript.{json,md}`, `summary.{json,md}`, `speakers.json`, `meta.json`; optional
  `variants/<tier>/` archives the non-active transcript tier. No `meta.json` = "Untranscribed".
- Dictations: `~/Kleoth/dictations/<yyyy-MM-dd>.json`; dictionary `~/.config/kleoth/dictionary.json`.
  A PENDING row (transcription failed/stopped) has empty texts, `insert_method: "none"`,
  `audio_file_name` → `dictations/audio/<id>.m4a`, `transcription_error`; a retry fills it in place.
- Screen recordings: `~/Kleoth/screen-recordings/screen-<stamp>.mp4` + `<stem>.json` sidecar (words).
- Config: `~/.config/kleoth/config.json` (CLI) and ONE consolidated Keychain item (service `dev.kleoth`,
  account `settings`, JSON) read once per launch — click **Always Allow** on the prompt.
  UserDefaults: `dev.kleoth.dictation.pillPlacement`, `dev.kleoth.settings.page`,
  `dev.kleoth.screenRecording.permissionRequestedAt`.
- Stored keys are snake_case via `convert{To,From}SnakeCase` — **no acronyms in stored property
  names** (`transcriptionUSD` does not round-trip; `CostBreakdown` uses explicit CodingKeys).

## Key decisions (do not relitigate)
- **Transcription:** tier 0 = on-device WhisperKit `large-v3-v20240930_626MB`, auto language (chosen
  over Apple Speech because it lacks Russian, the user's main language); tier 1 = ElevenLabs Scribe
  on demand ("Fully transcribe"). Mic and system are separate channels → You/Them for free; Scribe
  gets a mono mix + diarization mapped to channels by per-cluster energy (96% accurate on a live A/B).
  Auto-transcribe after recording is opt-in (`auto_transcribe`). Duration always comes from the audio file.
- **WhisperKit language:** `detectLanguage` defaults to false, so `language: nil` silently means "en".
  `LocalTranscriber.resolveLanguage` runs one global detect pass; pinnable via `transcription_language`.
  First model load after a new binary takes ~4 min (Core ML re-specializes); the next is ~1 s.
- **Summarization:** OpenRouter, default `ModelCatalog.defaultModel` = `z-ai/glm-5.3-flash`; strict
  `json_schema` with fallback to `json_object`; output language = transcript language. Summary shape is
  lean: `title?`, `tldr`, `overview?`, `action_items`, `per_speaker_highlights`.
- **Summary completeness (2026-09-24):** `Summarizer.assess` accepts an answer only if it is not cut off
  (finish `"length"`, or JSON that stops before it closes — Codex, Claude Code and some local servers
  say `"stop"` regardless), decodes, and has a non-blank `tldr` and non-null `overview`, `action_items`,
  `per_speaker_highlights` (blank/empty OK). ONE retry shaped by the failure (cut off → fresh, 2× budget,
  compact; `reasoning: low` only after an EMPTY cut-off; an empty answer is never replayed), then it
  throws. Nothing partial is ever saved; `meta.json` names `model`/`summary_provider` only if that run
  wrote one.
- **Dictation retry (2026-09-23):** Scribe budget per attempt = `min(120, 25 + 0.5 × clip s)`, one
  retry 1 s after a transient failure (timeout, network, 408/429/5xx); dictation URLSession 130 s/150 s
  so the budget always fires first. A run with no transcript (failed, prep failed, Esc/Settings-off
  while transcribing — not quit) KEEPS its clip as a pending row; pill "… — saved to History" + Retry
  (pastes); History "Try again in cloud / on device" is a background job that copies (on device via
  `enqueuePipelineJob`). Pasted dictations still keep no audio.
- **Hands-free mid-hold (2026-09-24):** tap ⌘ while fn+shift is held, or click the push-to-talk pill →
  the same capture goes hands-free (`ChordEdgeDetector` `latch` → `.latchKey`; pill → `.externalLatch`;
  both → `.latched`). A MODIFIER on purpose: the monitor is listen-only, so Space would be typed into
  the target app. Only from a confirmed hold; ⌥/⌃ mid-hold still end. Dictation design §10.3 item 16.
- **Dictation polish:** `DictationDefaults.polishModel` = `google/gemini-3.5-flash-lite` (~1 s),
  fallback glm-5.3-flash; `PolishGate` skips chat targets and < 24 words; `AppStyle` = compose/chat only.
- **OpenRouter account guardrails:** no-train + ZDR settings turn `require_parameters: true` into 404s
  for `openai/*`, `mistralai/*`, `x-ai/*`, and for `google/gemini-3.8-flash` when `temperature` is sent.
  The client retries a 400/404 without temperature/reasoning. "The key doesn't work" = this 404.
- **Un-sandboxed, self-signed:** `TextInserter` posts `CGEvent`s (blocked by App Sandbox). Never add
  `com.apple.security.app-sandbox` to `app/bundle/Kleoth.entitlements`. Accessibility + Screen
  Recording trust are bound to the "Kleoth Self-Signed" identity. Self-signed SCK capture works on this Mac.
- **Microphone:** one app-wide input-device pick (`input_device`, empty = Automatic) honoured by all
  three captures, set via `kAudioOutputUnitProperty_CurrentDevice` before reading `inputFormat(forBus:)`.
- **Pill:** dark capsule docked to a screen edge (`PillPlacement.edge` + fraction), tucked half off-screen
  when idle, hover → peek dock (Dictate · Record · More), own `PillMenuPanel` (never `NSMenu` — refused
  for inactive apps). Panel frames are set by the controller; SwiftUI never animates the window.
- **Screen recording:** SCStream screen + audio + a third `AVAudioEngine` mic tap mixed to ONE AAC track;
  H.264 ≤ 1920 px, 30 fps, fMP4 10 s fragments (player compatibility unverified — `fragmentInterval`
  nil is the retreat). Whole-app SCK exclusion keeps Kleoth's windows out of frame. Recordings are not
  meetings; they auto-transcribe on device with word timestamps after save.
- **UI wording:** tier badges say "On-device" / "Cloud". Money appears only in Settings → Usage.
  History deletes go to Trash without confirmation (Finder norm). No illustration in Settings or forms.
- **AI providers (2026-09-16):** `ChatCompleting` is the seam under `Summarizer`/`DictationPolisher`;
  backends = OpenRouter, local OpenAI-compatible server, Claude Code CLI (`claude -p` with settings/MCP
  isolation + `--system-prompt`, prompt on stdin), Codex CLI (summaries only), Apple on-device (dictation
  only, `KleothOnDevice` target, weak-linked). `ProviderResolver` auto order: local → Claude Code → Codex →
  OpenRouter → Apple. `ProviderDetector` caches its snapshot for 600 s, dropped on every provider-setting
  write, `applicationDidBecomeActive`, and the Settings Refresh button. Keys: `ai_provider`,
  `local_server_url`, `local_server_key`, `ai_models`; meta `summary_provider`, log `polish_provider`
  (nil = OpenRouter). OpenRouter's own model still comes from the legacy `default_model`/`dictation_model`
  keys via `Settings.effectiveProviderSettings`, with `ai_models` overrides taking priority. Design:
  `docs/plans/2026-09-15-ai-providers.md`.
- **Consent window (2026-09-24):** the consent guard lives ONLY in `RecordingController.start()`; a
  refusal bumps `consentRequest`, and the always-mounted menu-bar label opens "Before you record" on it
  (`onChange` + a mount-time check). New start paths (pill meeting button, call detection) just call
  `start()` — no consent check of their own (only the popover and onboarding, which show the notice in
  place, gate first). The window's start button never closes it; it closes itself once `isRecording`
  is true.
- **Positioning (2026-09-24):** the public pitch (tagline, GitHub About/topics, README hero, cask/Raycast/
  DMG text, hero + social-preview images) is written ONLY in `marketing/positioning.json`; `bun marketing/sync.ts
  apply` writes the rest — never hand-edit the README `positioning`/`release` blocks. Three jobs: Dictate · Meet ·
  Record screen (beta). Dictation is "Wispr Flow-style", never "alternative", while its STT is Scribe (cloud); held-back
  claims are listed in `marketing/README.md`. Release gate: `reviewed_for` must equal the version; the
  `.claude/settings.json` PreToolUse hook blocks `git tag vX.Y.Z` / `gh release create` until `check` passes.

## Gotchas
- `AppDelegate` → `@MainActor` controllers: use `MainActor.assumeIsolated`, never a `Task` hop
  (`applicationWillTerminate` may exit first).
- Any AVFoundation call that can raise (`installTap`, `connect`) goes through `catchingObjCExceptions`;
  a swallowed NSException surfaces later as a crash in `swift_task_isCurrentExecutor`.
- Read `inputNode.inputFormat(forBus:)`, not `outputFormat` — the latter is stale after a device switch.
- One `AVAudioEngine` per capture SESSION: create in `start()`, release on every exit, or a Bluetooth
  headset stays stuck in HFP (16 kHz) until the engine object is freed.
- AAC bit rate must be clamped per sample rate/channels (`AudioFormat.aacSettings`); a 16 kHz headset
  mic rejects 64 kbps with `'!dat'`.
- Off-main audio work: `Recorder.combine`, `ChannelAudio.mixToMono` take seconds — `Task.detached`.
- `vDSP_measqv` is the MEAN of squares; `sqrt` of it is the RMS. Not a bug.
- `NSEvent.keyCode`/`characters` on a mouse event raise and AppKit swallows the exception WITH the
  event (a dead click, no log). Check `event.type` first in any monitor matching both.
- An `NSHostingView` must never be a floating panel's `contentView` (SwiftUI's window-size bridge
  fights a controller-set frame → AppKit layout-loop abort). Wrap it in a plain container; set frames
  under `withTransaction(disablesAnimations)`. `pillsandbox` (AppKit lifecycle) cannot catch this.
- `import AVKit` alone does not link AVKit under SwiftPM; `KleothApp` has `.linkedFramework("AVKit")`.
  Verify with `otool -L … | grep AVKit`.
- Adding a KleothCore source file is invisible to a warm `app/.build` until
  `app/.build/arm64-apple-macosx/debug/description.json` is deleted.
- `Transcriber: Sendable` conformance must be declared in the type's own file.
- `zsh` has a `log` builtin — use `/usr/bin/log`. Synthetic `CGEvent` clicks from the agent shell do
  nothing (no Accessibility for the terminal); drive the pill through `pillsandbox` film hooks.
- A shell-launched probe gets the TERMINAL's TCC grant; it proves nothing about Kleoth's own.
- App Intents don't surface in Shortcuts (SwiftPM skips `appintentsmetadataprocessor`); URL scheme works.
- System Events keystrokes go to whatever app is frontmost, and `open -a Kleoth` / `activate` do not
  reliably bring an agent app forward — check the frontmost process first, and never UI-script while
  the user is using the Mac (a stray ⌘, landed in Slack mid-meeting, 2026-09-23). Kleoth's own
  buttons respond to AX `click` once its window is open.
- SwiftUI `onChange` never fires for the value a view MOUNTS with: a request counter bumped just
  before `openWindow` does not reach the new window. History request sites also set
  `HistoryRouting.requestedScope`, consumed on appear.
- Provider detection: the local-server probe opens its own 2 s/3 s ephemeral `URLSession` (the default
  `URLSessionTransport` waits for connectivity and hangs forever with no server listening); `codex login
  status` prints "Logged in using ChatGPT" to **stderr**, not stdout — check both streams.
- Ollama's OpenAI-compatible `/v1` ignores a per-request `num_ctx` and reportedly drops the START of an
  over-long prompt without an error (its default context can be 4k): long meetings need
  `OLLAMA_CONTEXT_LENGTH` ≥ 32768 on the server. `assess` sees only the answer, so it can't catch the
  loss (summary spec §9 Q4).
- `-KleothSimulateFirstRun YES` reads consent + onboarding as not done for that launch only. It is read
  from the argument domain alone (`defaults write` does nothing) and writes nothing, and `--args`
  reaches only a NEW process (`pkill -x Kleoth` first). Read first-run state from
  `RecordingController`, never the Keychain, or the flag can't reach it.

## Security (hard rules)
- API keys are never printed or committed. `.env` and `config.json` are gitignored; inspect `.env`
  with `cut -d= -f1`. Live probes read the key into a shell var and put it only in a header.
- The repo is public — anything on `main` is world-readable.

## State (update in place, keep to a few lines)
- Hands-free mid-hold (2026-09-24, CHANGELOG `[Unreleased]`): core tests, app build, pill filmed (bottom/right
  edges, real click). Not yet human-verified: the real hotkey — dictation design §10.3 item 16 checklist (a)–(e).
- Dictation retry merged to main 2026-09-24 (unreleased; CHANGELOG `[Unreleased]`): length-scaled
  Scribe budget + one retry, kept audio for failed/stopped dictations, pill Retry, History "Not
  transcribed" rows with Try again, History opening on the requested tab. Verified: 466 core tests,
  both packages build, pill filmed, probe retry against live Scribe, History pane rendered with a
  real pending row (test row removed), an independent review. Not yet human-verified: design doc §6
  checklist (pill Retry, History Try again on both engines, Esc while transcribing).
- Not human-verified yet: the providers checklist (provider rows on this Mac, a meeting via
  Automatic → `summary_provider` in `meta.json`, a dictation via Automatic and via Apple on-device →
  `polish_provider` in the day file, signing out of Claude Code, a local Ollama server,
  `kleoth summarize <dir> --provider codex`); pill menu actions end to end; screen-recording manual
  checklist items 1–8 (design doc §8); recordings viewer checklist (design doc §7).
- Summary completeness + consent window (2026-09-24, unreleased; CHANGELOG `[Unreleased]`; design
  `docs/plans/2026-09-24-summary-truncation-and-onboarding-skip.md`): `Summarizer.assess` + one shaped
  retry (a cut-off, empty, incomplete or malformed answer is never saved), `meta.json` provenance only
  with a summary, `--max-output-tokens`, a Summarize button + summary failures pinned on the meeting,
  the "Before you record" window for hotkey/URL/intent starts, `-KleothSimulateFirstRun`. Verified:
  core tests, app build, per-task and whole-branch reviews. Not yet human-verified: design doc §6
  checklist items 2–12.
- Next (2026-09-24): context-aware dictation — in progress on `feat/dictation-context` (the T3 Code
  focus spike, `dictate --focus-probe`, awaits the user's run); then meetings in the pill (phase 1) +
  call detection (phase 2), then meeting covers (Codex engine; Apple's `ImageCreator` can't draw in the
  background). Designs (local until each branch lands): `docs/plans/2026-09-24-*.md`. After those:
  History as one timeline, then onboarding + positioning. Dropped: trimming silence before Scribe.
- Positioning (2026-09-24, branch `docs/positioning`): after merge run `bun marketing/sync.ts apply` (pushes GitHub
  About/topics), upload `docs/assets/social-preview.png` by hand, record the 3 demo GIFs (README slot). Later: a Kleoth
  landing page at **shck.dev/kleoth** (`~/projects/shck.dev`), fed from `positioning.json` (`marketing/README.md`).
- Open threads: `.scratch/video-recording-thread/` (shipped; depth checks only). `docs/CODE-REVIEW.md`
  stays local/uncommitted by request.
