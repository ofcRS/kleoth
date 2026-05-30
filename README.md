# Kleoth

**A local-first, bot-free meeting recorder for macOS.** Kleoth captures system + microphone audio locally, transcribes it with [ElevenLabs Scribe](https://elevenlabs.io) (with speaker diarization), summarizes it with Claude (via [OpenRouter](https://openrouter.ai)), and writes plain Markdown/JSON files you own. No bot ever joins your call, and audio only goes to *your own* API keys.

> *kleos* (Greek κλέος) — "that which is heard." From the Proto-Indo-European root \*ḱlew‑, "to hear."

Marginal cost is roughly **$0.24 per 1-hour meeting** (Scribe ≈ $0.22/hr + a Claude Haiku summary ≈ $0.02) — versus $10–40/user/month for hosted SaaS.

## Status

| Piece | State |
| --- | --- |
| `KleothCore` library + `kleoth` CLI (file → transcript → summary → Markdown/Slack) | ✅ Builds, 47 unit tests pass |
| Menu-bar app (`KleothApp`) + audio capture (`KleothCapture`) | ✅ Compiles; needs full Xcode to bundle, sign, and run as a menu-bar agent — see [`BUILD-APP.md`](BUILD-APP.md) |

Everything compiles under the Xcode **Command Line Tools** alone. Full Xcode is only required to produce the signed `.app` bundle and to grant the microphone/screen-recording permissions that live capture needs.

## Pipeline

```
audio file ─▶ ElevenLabs Scribe ─▶ normalize ─▶ Claude (OpenRouter) ─▶ render ─▶ local files
              (diarized words)      (speaker        (JSON summary)      (Markdown /
                                     turns)                              Slack / checklist)
```

## Architecture

Two SwiftPM packages:

- **`kleoth`** (repo root, deployment target macOS 13) — `KleothCore` library + the `kleoth` CLI executable + tests.
  - `Models/` Codable, Sendable types · `Networking/HTTPTransport` (the `Sendable` seam clients depend on, mocked in tests) · `Transcription/` (`ScribeClient` streaming multipart upload + `TranscriptNormalizer`) · `Summarization/` (`OpenRouterClient` + `Summarizer`) · `Rendering/` (Markdown / action-items / Slack) · `SpeakerMapping/` · `Storage/MeetingStore` · `Config/` (`Credentials`, `Settings`) · `Pipeline/MeetingPipeline`.
- **`app/`** (deployment target macOS 14.4) — `KleothApp` (SwiftUI `MenuBarExtra`) + `KleothCapture` (Core Audio process-tap + AVAudioEngine + ScreenCaptureKit). Depends on `KleothCore` by path.

The only third-party dependency is `swift-argument-parser`. Everything else is Foundation + URLSession. All targets use the Swift 6 language mode.

## Requirements

- macOS 13+ (the menu-bar app needs macOS 14.4+ for the system-audio process-tap).
- A Swift 6 toolchain (developed against Swift 6.3.2). The CLI/library build with Command Line Tools; the app bundle needs full Xcode.
- An **ElevenLabs API key with the `speech_to_text` permission enabled** (see Configuration).
- An **OpenRouter API key** (only needed for summaries).

## Build & run

```sh
# Library + CLI
swift build
swift run kleoth --help
```

## Configuration

Keys are resolved in this order (first hit wins), and are **never** printed or committed:

1. Environment variables: `ELEVEN_API_KEY` (or `ELEVENLABS_API_KEY`), `OPENROUTER_API_KEY`.
2. A `.env` file in the working directory (`KEY=value` lines; `.env` is git-ignored).
3. `~/.config/kleoth/config.json` — `{ "eleven_api_key": "…", "openrouter_api_key": "…", "slack_webhook": "…" }`.

Example `.env`:

```sh
ELEVEN_API_KEY=sk_...
OPENROUTER_API_KEY=sk-or-...
```

> ⚠️ **ElevenLabs key scope:** the key must have the **`speech_to_text`** permission. A key without it authenticates but returns `401 {"status":"missing_permissions"}` on transcription. Enable it under your key's settings in the ElevenLabs dashboard.

Output defaults to `~/Kleoth/<meeting-slug>/` (override per command with `--out`). Each meeting folder holds `transcript.json` (raw Scribe response), `transcript.md`, `summary.json`, `summary.md`, `speakers.json`, and `meta.json` (includes the cost breakdown).

## CLI usage

```sh
# Transcribe an audio file (diarized). Prints speaker turns + cost, saves the meeting.
swift run kleoth transcribe meeting.m4a --num-speakers 2

#   --language en      hint a language (auto-detected when omitted)
#   --out ./out        output directory (default: ~/Kleoth)
#   --multi-channel    one speaker per channel (for 2-track mic+system recordings)

# Transcribe (if needed) and summarize. Needs an OpenRouter key.
swift run kleoth summarize meeting.m4a
swift run kleoth summarize ~/Kleoth/meeting          # summarize an already-transcribed meeting in place
#   --model anthropic/claude-sonnet-4.6   override the model (default: Haiku 4.5)
#   --no-transcript                       omit the full transcript from summary.md

# Assign real names to "speaker_0", "speaker_1", … (interactive; shows sample turns).
swift run kleoth rename ~/Kleoth/meeting

# Render the summary for Slack; posts to a webhook, or prints if none is set.
swift run kleoth slack ~/Kleoth/meeting --webhook https://hooks.slack.com/services/...
```

## Tests

`KleothCore` has 47 unit tests (network fully mocked via the `HTTPTransport` seam; no live API calls).

The Command Line Tools SDK does **not** ship the `XCTest` module, so the suite uses [`swift-testing`](https://github.com/apple/swift-testing) (`import Testing`). Under full Xcode, `swift test` works as-is. Under Command Line Tools only, the framework search paths must be passed explicitly:

```sh
swift test \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -L -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

## Consent & legal

Recording conversations is regulated, and the rules vary by jurisdiction (many places require **all-party consent**). Kleoth records both sides of a call without a visible bot — that is a discretion/UX feature, **not legal cover**. Comparable products (Otter, Fireflies) are in active privacy litigation as of 2026. **Get every participant's consent before recording.** The app surfaces a consent acknowledgement and a recording indicator, and stamps `consentAcknowledged` into each meeting's `meta.json`.

## Roadmap

- Menu-bar app: bundle, sign, notarize, and live-test capture — see [`BUILD-APP.md`](BUILD-APP.md).
- Later: fully-offline mode (Whisper.cpp + pyannote), live captions (Scribe v2 Realtime), Obsidian/Linear/git integrations, an optional hosted sync tier.
- Windows is intentionally out of scope (Mac-only, native, resource-light).

## License

Intended: **Apache-2.0** for the core (keep GPL-licensed audio dependencies out of the bundle). Add a `LICENSE` file before publishing.
