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
swift build && swift test                        # core + CLI (735 tests)
swift build --package-path app                   # app package
bash app/setup-signing.sh                        # once: "Kleoth Self-Signed" cert (Accessibility/TCC trust binds to it)
bash app/make-app.sh release                     # bundle + sign + install /Applications/Kleoth.app
pkill -x Kleoth; open -a Kleoth                  # relaunch (make-app does NOT kill the running instance)
pkill -x Kleoth; open -a Kleoth --args -KleothSimulateFirstRun YES   # first-run flows again, this launch only
bash app/make-dmg.sh                             # app/dist/Kleoth-<version>.dmg (version = app/bundle/Info.plist)
swift run kleoth summarize <dir> --model <slug> --provider claude-code|codex|local|openrouter  # re-summarize in place
swift run kleoth illustrate <dir>... [--engine codex|openrouter|local] [--style …] [--dry-run] [--force]   # meeting covers

# Headless probes (use --product, not --target — --target links no binary)
swift build --package-path app --product localtranscribe && app/.build/debug/localtranscribe <meeting-dir> [scribe]
swift build --package-path app --product dictate && app/.build/debug/dictate 4 [--no-polish] [--device <uid>] [--provider claude-code|codex|local|openrouter] [--text "<raw>" --runs N]
app/.build/debug/dictate --file <audio> [--fail-first N] [--keep-on-failure]   # real clip through the Scribe retry policy; N injected transient failures; keep → a REAL pending History row
app/.build/debug/dictate --text "<raw>" [--before s] [--after s] [--selection s | --reference s] [--single-line] [--no-polish]   # synthetic focused field → placement, gate, paste; `--focus-probe --help` = the AX probe (reads the app in front: only with the user)
swift build --package-path app --product screenrec && app/.build/debug/screenrec 10 [--inspect f.mp4] [--extract f.mp4] [--words f.m4a] [--sidecar f.mp4 --title T]
swift run --package-path app pillsandbox                                # pill playground
app/.build/debug/pillsandbox --film <dir> --edge right --sequence idle,armed,listening,done,idle   # filmstrip PNGs (step@secs; --demo dictation|screen composes README frames)
bash app/branding-src/demo/make-demos.sh                          # README demo GIFs from the real pill → docs/assets/demo-*.gif
bash app/branding-src/demo/make-app-demos.sh [data-dir]            # meeting + viewer GIFs, screenshot-detail.png: a KleothDemo.app copy (-KleothDemo) films its own window
bun app/branding-src/demo/make-demo-data.ts <dir> [--provider local]   # fictional meetings/recording, real on-device transcripts + summaries (default: Claude Code)
bun ~/.claude/skills/gpt-images/scripts/gpt-images.ts app/branding-src/<set>/jobs.json           # brand imagery (brief: app/branding-src/BRAND.md)
bun marketing/sync.ts check [--offline] | apply [--no-remote]   # public pitch: drift report / rewrite README hero, cask, Raycast, images, GitHub About+topics
bun test ./marketing/sync.test.ts                              # release-gate command parser
```
Logs: `/usr/bin/log stream --predicate 'subsystem == "dev.kleoth"'` (categories `Dictation`,
`DictationHotkey`, `Covers`, `PillTrace` — the latter needs `defaults write dev.kleoth.app KleothPillTrace -bool YES`).
Crash reports: `~/Library/Logs/DiagnosticReports/Kleoth-*.ips`. Reset TCC: `tccutil reset ScreenCapture|Accessibility dev.kleoth.app`.

## Architecture — two SwiftPM packages
**Root package** (macOS 13, dep: swift-argument-parser)
- `KleothCore`: Models, `HTTPTransport` seam, `Transcription/` (`Transcriber` protocol, `ScribeClient`,
  normalizer), `Summarization/` (`OpenRouterClient`, `Summarizer`, `ModelCatalog`), Rendering,
  SpeakerMapping, `Storage/MeetingStore`, `Config/` (Settings, Credentials, Keychain), `Pipeline/`,
  `Dictation/` (chord machine, polisher, log store, `PillGeometry`, `PolishGate`,
  `DictationTranscription` = Scribe budget + retry policy, `DictationAudioStore` = kept clips,
  `DictationContextPolicy`/`DictationContextFit`/`DictationInsertionPlan` = field context), `ScreenRecording/`
  (defaults, geometry, session machine, audio math, `Record`/`Store` transcript sidecar), `Usage/`,
  `Covers/` (drawing, store, engines), `Concurrency/` (`withTimeout`, `withDeadline`).
- `kleoth` CLI: `transcribe`, `summarize`, `rename`, `render`, `illustrate`. `KleothCoreTests`.

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
  `DictationController`, `FocusedTextReader` (the only code that reads another app's text),
  `ScreenRecordingController`, `PillCoordinator` (single face in front of the pill: dictation, screen
  recording, meetings), `Meetings/` (`MeetingCaptureTypes`, `MeetingPillBridge` = the meeting side's face
  in front of the pill), `AppConfig` (Settings + Keychain overlay), `Covers/CoverController`, `Views/` (MenuView, HistoryView with
  Meetings | Dictations | Recordings scopes, `MeetingCoverTile`/`MeetingCoverBand`, SettingsView = flat `HStack` sidebar over
  `SettingsPage`, `SettingsCoversSection`, Onboarding, recordings viewer), App Intents, `kleoth://` URL scheme.
  No test target.
- Executables: `taptest`, `localtranscribe`, `dictate`, `screenrec`, `pillsandbox`.

Design docs (binding contracts, error matrices, manual checklists): `docs/plans/2026-09-03-dictation.md`,
`docs/plans/2026-09-06-screen-recording.md`, `docs/plans/2026-09-07-recordings-viewer.md`,
`docs/plans/2026-09-23-dictation-retry.md`, `docs/plans/2026-09-24-summary-truncation-and-onboarding-skip.md`,
`docs/plans/2026-09-24-positioning.md`, `docs/plans/2026-09-24-demo-mode.md` (`-KleothDemo`: what a demo launch must never do),
`docs/plans/2026-09-24-meeting-illustrations.md`, `docs/plans/2026-09-24-dictation-context.md`,
`docs/plans/2026-09-24-meetings-in-the-pill.md`.

## Data on disk
- Meeting = `~/Kleoth/meeting-yyyy-MM-dd-HHmmss/`: `mic.m4a`, `system.m4a`, `meeting.m4a`,
  `transcript.{json,md}`, `summary.{json,md}`, `speakers.json`, `meta.json`; optional
  `variants/<tier>/` archives the non-active transcript tier. No `meta.json` = "Untranscribed".
- Meeting covers: `cover.jpg` + `cover.json` (`CoverRecord`: `drawn`/`skipped`/`removed`; `skipped`/`removed`
  block automatic redraws) in the meeting folder; a dropped-in `cover.png` shows too; no key in `meta.json`.
  Keys `cover_engine` (Off is written `"off"`, never empty), `cover_automatic`, `cover_style`, `cover_models`.
- Dictations: `~/Kleoth/dictations/<yyyy-MM-dd>.json`; dictionary `~/.config/kleoth/dictionary.json`.
  A PENDING row (transcription failed/stopped) has empty texts, `insert_method: "none"`,
  `audio_file_name` → `dictations/audio/<id>.m4a`, `transcription_error`; a retry fills it in place.
  Rows carry `field_context` (`cursor|merged|appended|replaced|reference|selection_changed`),
  `replaced_text` (merges only) and `context_seconds`; the text around the caret is never stored.
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
- **Context-aware dictation (2026-09-24):** `FocusedTextReader` is the ONLY code that reads another
  app's text (decisions: pure KleothCore). Wake at chord-down, snapshot at release ≤ 0.3 s, re-check
  before ⌘V ≤ 0.15 s. Selection ≤ 4,000 chars → merged; ≤ 20,000 → dictation after it; unreadable or
  longer → replaced; changed → dictation as heard (`polished_text` = `raw_text`). Caret context:
  1,500 before / 500 after. Terminal selection = reference. Only OpenRouter + Claude Code get it.
  `dictation_context` is off only as the STRING `"false"`; both wake lists are empty (design §10).
- **OpenRouter account guardrails:** no-train + ZDR settings turn `require_parameters: true` into 404s
  for `openai/*`, `mistralai/*`, `x-ai/*`, and for `google/gemini-3.8-flash` when `temperature` is sent.
  The client retries a 400/404 without temperature/reasoning. "The key doesn't work" = this 404.
- **Un-sandboxed, self-signed:** `TextInserter` posts `CGEvent`s (blocked by App Sandbox). Never add
  `com.apple.security.app-sandbox` to `app/bundle/Kleoth.entitlements`. Accessibility + Screen
  Recording trust are bound to the "Kleoth Self-Signed" identity. Self-signed SCK capture works on this Mac.
- **Microphone:** one app-wide input-device pick (`input_device`, empty = Automatic) honoured by all
  three captures, set via `kAudioOutputUnitProperty_CurrentDevice` before reading `inputFormat(forBus:)`.
- **Pill:** dark capsule docked to a screen edge (`PillPlacement.edge` + fraction), tucked half off-screen
  when idle, hover → peek dock (Dictate · Meeting · Screen · More), own `PillMenuPanel` (never `NSMenu` — refused
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
- **Meeting covers (2026-09-24):** Off by default; engines Codex (`codex exec` `image_gen`, `--ephemeral`, ChatGPT
  plan), OpenRouter (`POST /api/v1/images`, `google/gemini-3.1-flash-lite-image`) and a local server (Ollama
  `x/flux2-klein`). No Apple `ImageCreator`: deprecated 2026-06-11, dead on macOS 27, background-forbidden on 26.
  A scene step through the summary provider sees only the title + TL;DR + the first 1,500 overview chars; the
  image engine gets only the scene. Sensitive → `skipped`, no image call. One retry 2 s after a transient
  failure (HTTP engines only); budgets: scene 60 s (never retried), image local 300 / Codex 240 / OpenRouter
  90 s. Cloud jobs run on `CoverController`'s own serial tail, local ones via `enqueuePipelineJob`; a cover
  never marks a meeting processing. Money only in Settings → Usage (the covers row sums `cover.json` `cost`).
  Presentation (2026-09-25): the meeting page is one scroll (player included) that opens with the cover full width
  (`CoverHeroGeometry`: width ÷ 2 clamped 200–400 pt, parallax 0.35 with 80 pt of hidden reveal, overscroll
  stretch, none under Reduce Motion; `visualEffect` + `.scrollView`, macOS 14), title + TL;DR under it, Quick Look
  on click, the menu on right-click / `…` or a header chip without a picture; rows 56 pt only with a picture or a
  job; a demo launch shows covers (`showsCovers`) and draws none. Design: `docs/plans/2026-09-24-meeting-illustrations.md`
  (§10 addendum for the full-width cover).
- **Meetings in the pill (2026-09-25):** the meeting bar shows for EVERY meeting (any start path; dictation off
  or the pill hidden for the hour too — the hot-mic rule). `.saving` is owner-checked (both captures use it);
  one queued confirmation slot with its owner. The pill's Meeting button just calls `start()` (consent = the
  "Before you record" window, nothing of its own). Phase 2 (call detection) not built yet. Design:
  `docs/plans/2026-09-24-meetings-in-the-pill.md` (§10 lists the deviations).

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
- `CoverDrawing.draw` runs off the main actor as a nonisolated async call — never wrap it in `Task.detached`
  (cancellation would not propagate). Holds while `NonisolatedNonsendingByDefault` stays off.
- The meeting page's `NSScrollView` runs under the toolbar (`contentInsets.top` 52 pt on macOS 26): at rest its
  clip sits at y = -inset, so AppKit scroll offsets (`DemoDirector`) add the inset back; SwiftUI's `.scrollView`
  minY is already 0 at rest (probed on 26 only).
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
- `IsSecureEventInputEnabled()` is session-wide: a background Chromium browser can hold it with another app
  in front. `ioreg -l -w 0 | grep kCGSSessionSecureInputPID` names the holder (only while it's on; it can
  outlive a quit app by ~30 s). A windowless process is credited to the frontmost app.
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
- AX timeouts go on EACH element read (`AXUIElementSetMessagingTimeout`), never on the system-wide
  element — that sets it for the whole process.
- Chromium/Electron build their AX tree only once a client reads the APPLICATION element's `AXRole`:
  that read is the chord-down wake. The first dictation after such an app launches may get no context.
- Terminals are recognized by bundle id BEFORE the role: Ghostty's screen reports `AXTextArea` like
  an editor, but ⌘V goes to the program's input, never over the selection.
- `DictationPrompt.system`/`schemaJSON` are SHA-256-pinned: no-context polish requests stay
  byte-identical (providers cache the prefix). `contextSystem` is `system` plus string replacements
  (the `\nOUTPUT\n` line, `language`'s wording): keep those anchors, and re-pin only on purpose.
- Pill backdrops (`PillCoordinator.recompute()`): screen recording > meeting > resting pill > hidden. `setBackdrop`
  takes over only a resting-family phase (otherwise it just stores it) and the pill applies `model.phase` a
  main-queue turn late, so a capture start sets its backdrop FIRST, then dismisses its own leftover phase
  (`MeetingPillBridge` `.started`); `clearCapturePhaseBlocking` withdraws the other capture's. The other order
  leaves a hot mic with no bar.
- `referenceSize` is resolved against the four-field dock (275 pt, every edge) and, on bottom/top, the meeting
  bar (240 pt): a new longest shape must be folded in there, or a pill parked near a corner creeps.

## Security (hard rules)
- API keys are never printed or committed. `.env` and `config.json` are gitignored; inspect `.env`
  with `cut -d= -f1`. Live probes read the key into a shell var and put it only in a header.
- The repo is public — anything on `main` is world-readable.

## State (update in place, keep to a few lines)
- v0.5.0 (2026-09-25): hands-free mid-hold, dictation retry + pending dictations, summary completeness + the
  "Before you record" window, meeting covers (opt-in), the secure-input holder named, macOS 15 first-launch copy.
  The user verified hands-free and dictation retry in daily use and waived the other manual checklists
  (providers, pill menu, screen recording, recordings viewer, summary §6) on 2026-09-25.
- Covers hero (2026-09-25, unreleased; CHANGELOG `[Unreleased]`): full-width band + parallax + Quick Look + 56 pt
  rows + scene prompt rev. 4 + slash/temp fixes. Verified: core tests, both builds, `illustrate --dry-run`
  before/after. Still to film: the demo-mode frames (`KLEOTH_DEMO_FRAMES`: light/dark × 3 offsets, a no-cover page).
  Not yet human-verified: the Quick Look click, Reduce Motion, the rubber band, a window resize, "Show scroll bars:
  Always", the chip states with Covers on, macOS 14–15. Follow-ups: landscape covers (needs a paid look test), a
  bottom-pinned mini-player, a cover in the README demo data.
- Context-aware dictation (merged for 0.5.1; design `docs/plans/2026-09-24-dictation-context.md`): the field's
  selection + 1,500/500 chars around the cursor go to OpenRouter/Claude Code with the words; a selection merges in
  place. The user dictates with it daily; the design §6 checklist (1–24) was not run item by item.
- On-device meeting turns (merged for 0.5.1; demo-mode §6 #2): meetings transcribe with `LocalTranscriber.Timing
  .speechRuns` (word alignment, one entry per run of speech) and `TranscriptNormalizer` splits a `local-whisper`
  channel's turn where another channel spoke entirely inside the pause; Scribe grouping unchanged. Verified on
  fictional audio only (5/6 exact turn order); not yet on a real meeting or end to end in Russian.
- Meetings in the pill, phase 1 (for 0.5.1; `feat/meetings-in-the-pill`, in review): the four-field dock, the meeting
  bar for every meeting, "Meeting saved". Verified: core tests, both builds, code-read traces; the pill films are
  still to run. Not human-verified: design §6 manual items 1–6. The README pill GIFs (`make-demos.sh`) still show
  the three-field dock.
- Next, in order (for 0.5.1): call detection (meetings in the pill, phase 2). Designs (local until each branch lands):
  `docs/plans/2026-09-24-*.md`. Later: live help (spec + 24-task plan ready, deferred by the user), History as one
  timeline, onboarding. Dropped: trimming silence before Scribe.
- Positioning (2026-09-24): merged (PR #5); GitHub About/topics applied and social preview uploaded by hand
  2026-09-25. Demo GIFs: merged (PR #7). Later: a Kleoth
  landing page at **shck.dev/kleoth** (`~/projects/shck.dev`), fed from `positioning.json` (`marketing/README.md`).
- Demo films (2026-09-25, merged PR #7; no captions under the GIFs by choice): pill GIFs + meeting/viewer GIFs + screenshot, the last three from a
  `-KleothDemo` copy of the app (isolation verified: real data/defaults/Keychain/saved state unchanged). Found, not fixed
  (design `docs/plans/2026-09-24-demo-mode.md` §6): the Recordings empty state forces a ~900 pt History minimum height.
- Open threads: `.scratch/video-recording-thread/` (shipped; depth checks only). `docs/CODE-REVIEW.md`
  stays local/uncommitted by request.
