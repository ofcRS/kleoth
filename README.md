# Kleoth

<!-- positioning:start — generated from marketing/positioning.json by `bun marketing/sync.ts apply`; edit the JSON, not this block -->
<p align="center">
  <img src="docs/assets/hero.png" alt="Kleoth — Local-first voice, meetings and screen capture for macOS" width="830">
</p>

[![Release](https://img.shields.io/github/v/release/ofcRS/kleoth)](https://github.com/ofcRS/kleoth/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/ofcRS/kleoth/total)](https://github.com/ofcRS/kleoth/releases)
[![Platform: macOS 14.4+](https://img.shields.io/badge/platform-macOS%2014.4%2B-black)](https://www.apple.com/macos/)
[![Swift 6](https://img.shields.io/badge/swift-6-orange)](https://www.swift.org/)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

**Local-first voice, meetings and screen capture for macOS.**

Kleoth is an open-source Mac app for **system-wide dictation**, **bot-free meeting recording** and **screen recording with transcripts**. What it records and transcribes are plain files in `~/Kleoth` that you own; transcription can stay on your Mac, and the AI steps run on whatever you already use.

- **[Dictate anywhere](docs/dictation.md).** Hold fn+shift, speak, let go: cleaned-up text lands in whatever app has focus — an editor, a terminal, an AI chat, mail. Wispr Flow-style voice typing with a personal dictionary and a searchable history. Speech-to-text runs on ElevenLabs Scribe with your own key.
- **[Record meetings without a bot](docs/meetings.md).** Your mic and the call's audio (Zoom, Meet, Teams, anything that plays sound), recorded on your Mac with nobody joining the call. Transcribed on device with Whisper, summarized in the meeting's own language, saved as Markdown and JSON. A local, open-source alternative to Granola, and a bot-free one to Otter, Fireflies and tl;dv.
- **[Record your screen](docs/screen-recording.md) (beta).** A display or a region, with system audio and your mic, as a small MP4. Transcribed on device afterwards; the viewer highlights each word as it is spoken. Loom-style, but nothing is uploaded. No trimming, sharing or export yet.

**Bring your own AI — or none.** Summaries and dictation clean-up run on whatever you already use: Claude Code, Codex, a local Ollama or LM Studio server, OpenRouter, or Apple's on-device model. Kleoth doesn't sell you another AI subscription. [Which providers, and what each needs →](docs/ai-providers.md)

No account. No database. Local-first by design.
<!-- positioning:end -->

> *kleos* (Greek κλέος) — "that which is heard." From the Proto-Indo-European root \*ḱlew‑, "to hear."

<p align="center">
  <img src="docs/assets/demo-dictation.gif" alt="Dictation: hold fn+shift and talk; the pill listens, transcribes, cleans up, and the text is pasted into the editor" width="49%">
  <img src="docs/assets/demo-screen.gif" alt="Screen recording: click Record in the pill, the pill becomes a toolbar with a timer and audio meters, click Stop, the recording is saved" width="49%"><br>
  <em>Kleoth's real pill, rendered with sample content; the screen demo skips the region picker
  (<a href="app/branding-src/demo/make-demos.sh">how</a>).</em>
</p>

## Dictation: Wispr Flow-style voice typing in any app

Hold **fn+shift**, speak, let go: Kleoth transcribes what you said, cleans it up with one short
language-model pass (fillers and false starts gone, never translated) and pastes it into whatever
app has focus. If you know Wispr Flow or Superwhisper, it is the same hold-to-talk idea. Double-tap
for hands-free; from the next release, a hold that runs long can go hands-free too — tap ⌘ or click
the pill. In an editor, an AI chat or a terminal, a long spoken ramble comes back as the text you
would have typed — paragraphs, a list where you listed things; a quick chat message is pasted as
heard. A personal dictionary biases recognition toward your names and jargon, and every dictation
lands in a searchable history.

Speech-to-text runs on [ElevenLabs Scribe](https://elevenlabs.io) with your own key; the clean-up
runs on your AI provider. From the next release, a dictation that can't be transcribed keeps its
audio: it waits in History, and the pill's **Retry** — or History's "Try again", in the cloud or on
this Mac — transcribes it later. [More about dictation →](docs/dictation.md)

## Meetings: a local alternative to Granola, a bot-free one to Otter, Fireflies and tl;dv

Kleoth records your microphone and the call's audio directly on your Mac — Zoom, Google Meet,
Teams, a browser tab, anything that plays sound. No bot joins the call, and the audio stays on
your Mac unless you choose cloud transcription.

- **Transcribed on device** by Whisper ([WhisperKit](https://github.com/argmaxinc/WhisperKit) on the
  Apple Neural Engine). No account, no API key. The language is detected automatically — English,
  Russian and dozens more — or pinned in Settings.
- **You vs. Them, exactly** — your mic and the system audio are separate channels, so who said what
  needs no diarization guesswork.
- **Cloud transcription when it matters** — one click sends a meeting to ElevenLabs Scribe, with
  your key; the on-device version is kept alongside.
- **Summaries in the meeting's language** — TL;DR, overview, action items and per-speaker
  highlights, written after each transcription by your AI provider (on Automatic, the first one
  Kleoth finds — see [Bring your own AI](#bring-your-own-ai)).
- **Files, not a database** — every meeting is a folder of audio, `transcript.md`, `summary.md` and
  JSON in `~/Kleoth`. Grep it, sync it, delete it.

<p align="center">
  <img src="docs/assets/demo-meeting.gif" alt="The History window: a meeting's TL;DR and summary, its action items with owners and due dates, per-speaker highlights, then the next meeting" width="820"><br>
  <em>Kleoth's real History window over fictional meetings, transcribed on device and summarized by
  Claude Code (<a href="app/branding-src/demo/make-app-demos.sh">how</a>).</em>
</p>

[More about meetings →](docs/meetings.md)

## Screen recording: Loom-style, local (beta)

Pick "Record screen…" in the menu-bar popover (or hover the pill, shown while dictation is on), drag
a region or take the whole display, and Kleoth records it with system audio **and** your microphone as one small H.264 MP4 (about 22 MB
per minute) in `~/Kleoth/screen-recordings/`. Each recording is transcribed on device afterwards
and opens in a viewer with the transcript beside the video: the spoken word is highlighted, clicking
a word seeks, double-clicking corrects it. It is a beta — no trimming, sharing or export yet.
[More about screen recording →](docs/screen-recording.md)

<p align="center">
  <img src="docs/assets/demo-viewer.gif" alt="The recordings viewer: a narrated slide recording plays on the left while the transcript on the right highlights each word as it is spoken" width="820"><br>
  <em>The recordings viewer playing a demo recording; its word timings come from the on-device transcription.</em>
</p>

## Bring your own AI

Kleoth doesn't sell you another AI subscription. Summaries and dictation clean-up need a language
model, and Kleoth uses whatever you already have, in this order, unless you pick one in
Settings → Accounts:

| Provider | What it needs | Summaries | Dictation |
|---|---|---|---|
| Local server (Ollama, LM Studio, any OpenAI-compatible URL) | the server running, default `http://localhost:11434/v1` | ✓ | ✓ |
| Claude Code | the `claude` CLI installed and signed in | ✓ | ✓ (slow — several seconds per cleanup) |
| Codex | the `codex` CLI installed and signed in | ✓ | — |
| OpenRouter | an API key | ✓ | ✓ |
| Apple on-device | macOS 26 with Apple Intelligence on | — | ✓ |

Codex only summarizes (no dictation cleanup path); Apple's on-device model only cleans up
dictation and needs macOS 26 with Apple Intelligence turned on in System Settings.

Speech-to-text is separate from all of these: Whisper runs on device for meetings, screen
recordings and retries, and [ElevenLabs Scribe](https://elevenlabs.io), with your key, transcribes
dictation and anything you send to the cloud. More in [docs/ai-providers.md](docs/ai-providers.md).

**Long meetings on Ollama** need a larger context than Ollama's default, which can be as small as
4096 tokens: start the server with `OLLAMA_CONTEXT_LENGTH` set to 32768 or more
(`OLLAMA_CONTEXT_LENGTH=32768 ollama serve`; for the Ollama app, run
`launchctl setenv OLLAMA_CONTEXT_LENGTH 32768` and restart it). Ollama's OpenAI-compatible
endpoint (the `/v1` URL Kleoth uses) has no way to set the context size per request, and an
over-long prompt is reportedly cut from the start without an error — the summary may then cover
only the end of the meeting.

Nothing is sent anywhere you did not sign up for: the CLIs run as the binaries you installed,
with their own login; the local server and Apple's model never leave the machine.

**If Kleoth is useful to you, starring the repo helps other Mac users find it.** ⭐

## Requirements

- **macOS 14.4 or later.** Apple Silicon recommended (the on-device model runs on the Neural Engine).
- **~600 MB one-time download** for the Whisper model on first transcription, then fully offline.
- API keys are **optional**. An ElevenLabs key is needed for dictation and cloud transcription;
  summaries can run on a provider that needs no key at all (see [Bring your own AI](#bring-your-own-ai)).

## Screenshots

<p align="center">
  <img src="docs/assets/screenshot-detail.png" alt="The History window: a day-grouped meeting list beside a meeting's TL;DR and AI summary" width="900"><br>
  <em>The History window — searchable, day-grouped meetings with a TL;DR, summary, action items, and per-speaker highlights (demo data).</em>
</p>

<p align="center">
  <img src="docs/assets/screenshot-popover.png" alt="The Kleoth menu-bar popover with a Start Recording button and recent meetings" width="330"><br>
  <em>The menu-bar popover — start a recording and reach recent meetings.</em>
</p>

<!-- TODO: screenshot — first-run onboarding (Settings → Show Welcome Window) -->

## Install

<!-- release:start — generated from app/bundle/Info.plist + app/dist by `bun marketing/sync.ts apply` -->
**[⬇ Download Kleoth-0.4.0.dmg](https://github.com/ofcRS/kleoth/releases/download/v0.4.0/Kleoth-0.4.0.dmg)**
(13.7 MB · [SHA-256](https://github.com/ofcRS/kleoth/releases/download/v0.4.0/Kleoth-0.4.0.dmg.sha256))
— or browse all [Releases](../../releases).
<!-- release:end -->

Open the DMG and drag **Kleoth.app** onto the **Applications** folder. Kleoth lives in the menu bar
(the lyre icon).

### First launch (current builds are self-signed)

Until Kleoth ships notarized builds, macOS Gatekeeper will warn that it is from an unidentified
developer. This is expected — the app is signed, just not yet with an Apple-issued Developer ID.

1. In **Applications**, **right-click Kleoth.app → Open** (don't double-click the first time).
2. In the dialog, click **Open** again. macOS remembers the choice; subsequent launches are normal.

This step exists only because notarization requires an Apple Developer Program membership (planned —
see [Roadmap](#roadmap)). The build is otherwise complete and signed.

<!-- Once notarized + a Homebrew tap exists:
```sh
brew install --cask kleoth
```
-->

## Permissions Kleoth requests, and why

| Permission | Why | When |
| --- | --- | --- |
| **Microphone** | Record your side of the conversation. | First recording. |
| **System Audio Recording** | Record the other participants (the audio your Mac plays). Shown under *Privacy & Security → Screen & System Audio Recording*. | First recording. |
| **Keychain** | Store your optional API keys securely. **Click "Always Allow"** so you are not re-prompted. | When you save a key, or on a re-signed build. |
| Calendar *(optional)* | Name a meeting from the calendar event you're in. Decline freely. | If you grant it. |
| Accessibility *(optional)* | Dictation only: watch for the fn+shift chord system-wide and send the ⌘V that pastes the dictated text. | When you turn dictation on in Settings. |
| Screen Recording *(optional)* | Screen recording only: capture the display or region you picked. Kleoth's own pill and picker are never in the frame. | The first time you start a screen recording. |

Everything except the microphone and system-audio grants is optional. The only place Kleoth sends
audio is ElevenLabs Scribe, with your key: each dictation, and a meeting or recording you choose to
transcribe in the cloud.

## Quick start

1. Open Kleoth from the menu bar and click **Start Recording** (or use the global hotkey).
2. Have your meeting. The menu-bar icon shows you're recording.
3. Click **Stop**. The recording is saved to your meeting list as *Untranscribed* — you can start
   another recording immediately.
4. Open the meeting and click **Transcribe** (free, on device) — or turn on "Transcribe
   automatically after recording" in Settings. When it finishes you have the transcript and, if an
   AI provider is available (see [Bring your own AI](#bring-your-own-ai)), the summary. The same content is on disk at `~/Kleoth/meeting-<timestamp>/` as `transcript.md` and
   `summary.md`.

That's it — no key required for steps 1–4.

## Configuration

Open **Settings** from the menu bar. Everything here is optional:

- **ElevenLabs API key** — enables the per-meeting **"Fully transcribe"** (Cloud) action. The key
  needs the `speech_to_text` permission.
- **OpenRouter API key** — one way to get AI summaries and the dictation clean-up pass (see
  [Bring your own AI](#bring-your-own-ai) for the others). Note: if your
  OpenRouter account blocks providers that may train on your data, choose a no-train model (e.g.
  `z-ai/*`, `deepseek/*`, `google/*`, `meta-llama/*`); accounts that enforce Zero Data Retention
  will also find `google/*` blocked (404 `zdr-violation-by-account`) — the default `z-ai/glm-5.3-flash`
  works under both guardrails; relax them at openrouter.ai/settings/privacy to use Gemini.
- **Summary model** — any OpenRouter model slug. Default: `z-ai/glm-5.3-flash`.
- **Transcription language** — *Auto* (detect per meeting) or pin a specific language.
- **Dictation** — enable hold-to-talk (fn+shift), pick the polish model (default
  `google/gemini-3.5-flash-lite`, the fastest correct one measured — ~0.9 s; if your account blocks
  Google the polish falls through to `z-ai/glm-5.3-flash`), edit your personal dictionary (one term per line; the first 100 are
  sent with each dictation), reset the pill position. Needs an ElevenLabs key; without an
  AI provider the raw transcript is pasted as-is.

Keys are stored in the macOS Keychain and are **never** printed or committed.

## CLI

The repo also ships a `kleoth` command-line tool for the same pipeline (audio file → transcript →
summary → Markdown), independent of the app:

```sh
swift run kleoth transcribe meeting.m4a   # ElevenLabs Scribe; diarized; saves the meeting
swift run kleoth summarize  <dir|file>    # transcribe (if needed) + AI summary  (--model <slug>)
swift run kleoth rename     <dir>         # assign real names to speaker_0 / speaker_1 …
swift run kleoth render     <dir>         # re-render summary.md from summary.json (no API calls)
```

Run `swift run kleoth <subcommand> --help` for flags. The CLI resolves keys from environment
variables (`ELEVEN_API_KEY`, `OPENROUTER_API_KEY`), a local `.env`, or
`~/.config/kleoth/config.json`.

`kleoth summarize --max-output-tokens <n>` sets the summary's output-token budget (default 8192;
an answer cut off at that limit is retried once with twice the budget). It applies to OpenRouter
and local servers only — the Claude Code and Codex CLIs take no output cap.

> **Free summaries in Claude Code:** the `summarize-meeting` project skill produces the same
> `summary.json` / `summary.md` using your Claude Code session — no OpenRouter key, zero API cost.
> Just ask it to summarize a meeting folder.

## Integrations

- **Raycast extension** — `integrations/raycast-extension/`. Toggle/Start/Stop Recording, Search
  Meetings (open/copy summary, transcript, and paths), and Latest Summary. Import with
  `npm install && npm run dev` in that directory.
- **Shortcuts / App Intents** — Start/Stop/Toggle recording as app intents (see
  `app/Sources/KleothApp`). Note: SwiftPM builds don't run Apple's App Intents metadata extractor, so
  intents may not auto-surface in Spotlight; the URL scheme and hotkey work regardless.
- **`kleoth://` URL scheme** — `kleoth://record`, `kleoth://stop`, `kleoth://toggle`,
  `kleoth://summarize-latest`. Callable from `open`, scripts, Raycast, etc.
- **Global hotkey** — bind a system-wide shortcut for toggle-recording in Settings.

## Data & privacy

**Recording and on-device transcription never leave your Mac**, and nothing ever goes to a Kleoth
server — there isn't one. What does leave, and when:

- **Audio** goes only to ElevenLabs Scribe, with your key: each dictation, and a meeting or
  recording you choose to transcribe in the cloud.
- **Transcripts** go to your AI provider: a meeting's, for its summary, right after it is
  transcribed; a dictation's, for clean-up. On **Automatic** (the default) that is the first
  provider Kleoth finds — local server, Claude Code, Codex, OpenRouter, Apple — so with no local
  server running and the Claude Code or Codex CLI signed in, your transcripts go to Anthropic or
  OpenAI under your account.
  To keep them on your Mac, pick a local server (Ollama, LM Studio) or, for dictation, Apple's
  on-device model in Settings → Accounts (see [Bring your own AI](#bring-your-own-ai)).

Each meeting is one self-contained folder, `~/Kleoth/meeting-yyyy-MM-dd-HHmmss/`:

```
mic.m4a · system.m4a · meeting.m4a   # your audio (mic, system, 2-channel combined)
transcript.json · transcript.md       # the transcript (raw + rendered)
summary.json   · summary.md           # the AI summary (if generated)
speakers.json                         # speaker_0 / speaker_1 → display names (You / Them)
meta.json                             # metadata: duration, tier, timestamps, consent
```

Dictations are text: `~/Kleoth/dictations/<yyyy-MM-dd>.json` holds the raw and polished text, the
target app, language, and models per utterance; the audio clip is deleted as soon as it has been
transcribed. Only a dictation whose transcription failed or was stopped keeps its clip, in
`~/Kleoth/dictations/audio/`, until it is transcribed or deleted. The personal dictionary is a
plain JSON array at `~/.config/kleoth/dictionary.json`.

Screen recordings are plain files in `~/Kleoth/screen-recordings/`: `screen-<timestamp>.mp4` plus a
`screen-<timestamp>.json` sidecar holding the title and the word-timed transcript. Editing a word in
the viewer rewrites only the sidecar; the movie is never touched.

**Consent:** recording conversations is regulated and the rules vary by jurisdiction — many places
require **all-party consent**. Kleoth records both sides without a visible bot; that is a UX choice,
**not legal cover**. Get every participant's consent before recording. The app surfaces a consent
acknowledgement and stamps it into each meeting's `meta.json`.

## Build from source

```sh
# Core library + CLI (deployment target macOS 13)
swift build && swift test                  # builds; runs the unit suite

# Menu-bar app (deployment target macOS 14.4)
swift build --package-path app             # compile-check the app + capture packages
bash app/setup-signing.sh                  # one-time: create the local "Kleoth Self-Signed" cert
bash app/make-app.sh release               # bundle, sign, install to /Applications

# Package a distributable DMG (self-signed tier)
bash app/make-dmg.sh                        # → app/dist/Kleoth-<version>.dmg (prints SHA-256)
```

The release process (version bump, the notarized public tier, tagging, `gh release`) is documented
in [`docs/RELEASING.md`](docs/RELEASING.md).

## Architecture

Two SwiftPM packages. **Package 1** (repo root, macOS 13) is `KleothCore` — models, networking
seam, transcription (ElevenLabs Scribe client + the engine-agnostic `Transcriber` protocol),
summarization (OpenRouter client), rendering, speaker mapping, storage, and the meeting pipeline —
plus the `kleoth` CLI. **Package 2** (`app/`, macOS 14.4) is the `KleothApp` SwiftUI menu-bar agent
and `KleothCapture` (Core Audio process-tap for system audio, AVAudioEngine for the mic, and the
`LocalTranscriber` built on WhisperKit). The only non-Apple core dependency is
`swift-argument-parser`; the app adds WhisperKit and KeyboardShortcuts.

## Roadmap

- **Notarized builds** — Gatekeeper-clean install (needs Apple Developer Program enrollment). The
  signing/notarization pipeline is already wired in `app/make-dmg.sh`, pending the certificate.
- **Homebrew cask** — `brew install --cask kleoth` once releases are notarized.
- **Sparkle auto-update.**
- **Whisper model-size picker** — trade accuracy for speed/size.
- A default-engine toggle (on-device vs. cloud) and live captions are under consideration.

## License

[Apache License 2.0](LICENSE), except the Raycast extension
(`integrations/raycast-extension/`), which is MIT-licensed — the Raycast Store requires MIT for
published extensions.

## Acknowledgments

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Argmax) — on-device Whisper inference on
  Core ML / the Apple Neural Engine.
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) (Sindre Sorhus) — the
  global hotkey.
- [ElevenLabs Scribe](https://elevenlabs.io) — optional cloud speech-to-text.
- [OpenRouter](https://openrouter.ai) — optional AI summaries across many models.
