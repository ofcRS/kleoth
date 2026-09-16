# Kleoth

Local-first, bot-free macOS meeting recorder + dictation + screen recording. Native Swift 6 /
SwiftUI menu-bar app and a `kleoth` CLI. Captures mic + system audio locally → transcribes →
summarizes → writes Markdown/JSON the user owns. Public repo: github.com/ofcRS/kleoth (Apache-2.0).

Keep this file short: commands, architecture, decisions, gotchas. Session narrative goes in
`docs/SESSION-LOG.md` (archived history) or the design docs under `docs/plans/`, never here.

## Environment
macOS 26 (Tahoe), Apple Silicon, Swift 6.3, Xcode 26. Floors: KleothCore/CLI = macOS 13; app = 14.4.
Liquid Glass gated behind `if #available(macOS 26, *)`.

## Commands
```bash
swift build && swift test                        # core + CLI (434 tests)
swift build --package-path app                   # app package
bash app/setup-signing.sh                        # once: "Kleoth Self-Signed" cert (Accessibility/TCC trust binds to it)
bash app/make-app.sh release                     # bundle + sign + install /Applications/Kleoth.app
pkill -x Kleoth; open -a Kleoth                  # relaunch (make-app does NOT kill the running instance)
bash app/make-dmg.sh                             # app/dist/Kleoth-<version>.dmg (version = app/bundle/Info.plist)
swift run kleoth summarize <dir> --model <slug> --provider claude-code|codex|local|openrouter  # re-summarize in place

# Headless probes (use --product, not --target — --target links no binary)
swift build --package-path app --product localtranscribe && app/.build/debug/localtranscribe <meeting-dir> [scribe]
swift build --package-path app --product dictate && app/.build/debug/dictate 4 [--no-polish] [--device <uid>] [--provider claude-code|codex|local|openrouter] [--text "<raw>" --runs N]
swift build --package-path app --product screenrec && app/.build/debug/screenrec 10 [--inspect f.mp4] [--extract f.mp4] [--words f.m4a]
swift run --package-path app pillsandbox                                # pill playground
app/.build/debug/pillsandbox --film <dir> --edge right --sequence idle,armed,listening,done,idle   # filmstrip PNGs
bun ~/.claude/skills/gpt-images/scripts/gpt-images.ts app/branding-src/<set>/jobs.json           # brand imagery (brief: app/branding-src/BRAND.md)
```
Logs: `/usr/bin/log stream --predicate 'subsystem == "dev.kleoth"'` (categories `Dictation`,
`DictationHotkey`, `PillTrace` — the latter needs `defaults write dev.kleoth.app KleothPillTrace -bool YES`).
Crash reports: `~/Library/Logs/DiagnosticReports/Kleoth-*.ips`. Reset TCC: `tccutil reset ScreenCapture|Accessibility dev.kleoth.app`.

## Architecture — two SwiftPM packages
**Root package** (macOS 13, dep: swift-argument-parser)
- `KleothCore`: Models, `HTTPTransport` seam, `Transcription/` (`Transcriber` protocol, `ScribeClient`,
  normalizer), `Summarization/` (`OpenRouterClient`, `Summarizer`, `ModelCatalog`), Rendering,
  SpeakerMapping, `Storage/MeetingStore`, `Config/` (Settings, Credentials, Keychain), `Pipeline/`,
  `Dictation/` (chord machine, polisher, log store, `PillGeometry`, `PolishGate`), `ScreenRecording/`
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
  Meetings | Dictations | Recordings scopes, SettingsView = `NavigationSplitView` over `SettingsPage`,
  Onboarding, recordings viewer), App Intents, `kleoth://` URL scheme. No test target.
- Executables: `taptest`, `localtranscribe`, `dictate`, `screenrec`, `pillsandbox`.

Design docs (binding contracts, error matrices, manual checklists): `docs/plans/2026-09-03-dictation.md`,
`docs/plans/2026-09-06-screen-recording.md`, `docs/plans/2026-09-07-recordings-viewer.md`.

## Data on disk
- Meeting = `~/Kleoth/meeting-yyyy-MM-dd-HHmmss/`: `mic.m4a`, `system.m4a`, `meeting.m4a`,
  `transcript.{json,md}`, `summary.{json,md}`, `speakers.json`, `meta.json`; optional
  `variants/<tier>/` archives the non-active transcript tier. No `meta.json` = "Untranscribed".
- Dictations: `~/Kleoth/dictations/<yyyy-MM-dd>.json`; dictionary `~/.config/kleoth/dictionary.json`.
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
- Provider detection: the local-server probe opens its own 2 s/3 s ephemeral `URLSession` (the default
  `URLSessionTransport` waits for connectivity and hangs forever with no server listening); `codex login
  status` prints "Logged in using ChatGPT" to **stderr**, not stdout — check both streams.

## Security (hard rules)
- API keys are never printed or committed. `.env` and `config.json` are gitignored; inspect `.env`
  with `cut -d= -f1`. Live probes read the key into a shell var and put it only in a header.
- The repo is public — anything on `main` is world-readable.

## State (update in place, keep to a few lines)
- Uncommitted: none on this branch. `feat/ai-providers` (five backends, T1–T13 implementation + this
  T14 docs pass, all committed) awaits the
  user's visual check of Settings → Accounts and the human checklist: provider rows on this Mac, a
  meeting via Automatic (`summary_provider` in `meta.json`), a dictation via Automatic and via Apple
  on-device (`polish_provider` in the day file), signing out of Claude Code, a local Ollama server,
  and `kleoth summarize <dir> --provider codex`.
- Not human-verified yet: all of the above, plus pill menu actions end to end, screen-recording
  manual checklist items 1–8 (design doc §8), recordings viewer checklist (design doc §7).
- Open threads: `.scratch/video-recording-thread/`. `docs/CODE-REVIEW.md` stays local/uncommitted by request.
