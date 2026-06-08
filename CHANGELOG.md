# Changelog

All notable changes to Kleoth are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Removed

- **Slack integration.** The Slack webhook export is gone — the `kleoth slack`
  CLI subcommand, the Settings webhook field, the "Post to Slack" Shortcut /
  App Intent, the `kleoth://slack-latest` URL verb, and the detail view's "Copy
  for Slack" action (replaced by a Slack-free **Copy Summary** that copies the
  rendered Markdown).

### Fixed

- Summaries are no longer silently truncated: completions cut off at the output
  cap (`finish_reason == "length"`) are retried with a larger budget and a
  truncated result is surfaced as a failure rather than shipped half-empty.
- The onboarding "Start your first recording" button no longer no-ops after
  "Skip setup" — it routes to the permissions step so consent is acknowledged.

## [0.1.0] — 2026-06-06

First public release. A local-first, bot-free macOS meeting recorder.

### Added

- **On-device transcription by default.** Records your microphone and the other participants'
  system audio locally and transcribes on the Apple Neural Engine via WhisperKit — free, offline,
  and private. The model (~600 MB) downloads once on first use, then nothing leaves your machine.
- **Automatic multilingual transcription.** The spoken language is auto-detected per meeting
  (English, Russian, and many more); summaries are written in that same language. The language can
  also be pinned in Settings.
- **Exact "You vs. Them" separation.** Mic and system audio are captured as separate channels, so
  speaker attribution is precise without diarization guesswork.
- **Menu-bar app.** A lightweight `MenuBarExtra` agent: start/stop recording, browse your meeting
  history, read transcripts and summaries, and rename speakers — all from the menu bar.
- **Finder-like meeting management.** In the History window: double-click a meeting to rename it
  inline, ⌘-click / ⇧-click to select several, and delete with ⌫ or the context menu — deletions
  go to the Trash (recoverable), and a Show in Finder action jumps to the meeting folder.
- **First-run onboarding.** A guided welcome flow (with a welcome chime) walks you through naming
  yourself, granting microphone and system-audio permissions, and downloading the model.
- **Optional cloud transcription.** A per-meeting one-click "Fully transcribe" action sends a
  meeting to ElevenLabs Scribe (using your own key) for state-of-the-art accuracy, at 1× cost via a
  mono mixdown with channel-energy speaker attribution.
- **Optional AI summaries.** Generates a TL;DR, an overview, action items, and per-speaker
  highlights via OpenRouter (any model; default `google/gemini-3-flash-preview`), using your own
  key. A title is generated for untitled meetings.
- **Background processing.** Stopping a recording returns instantly — the meeting moves into your
  list and transcribes in the background while you start the next one. Jobs run one at a time.
- **Files you own.** Every meeting is a self-contained folder in `~/Kleoth` with the audio,
  `transcript.md`, `summary.md`, and JSON. No database, no lock-in.
- **`kleoth` CLI.** `transcribe`, `summarize`, `rename`, `render`, and `slack` subcommands for the
  same pipeline outside the app.
- **Integrations.** A Raycast extension (toggle/start/stop recording, search meetings, latest
  summary), App Intents for Shortcuts, a `kleoth://` URL scheme, and a configurable global hotkey.
  Optional calendar access names a meeting from the event you're in.
- **Slack export.** Render and post a meeting summary (title + TL;DR + top action items) to a Slack
  webhook.
- **Settings & usage.** Manage optional API keys (stored in the Keychain), the summary model, and
  the transcription language; a Usage section reports provider-side credit/quota.
- **Distribution.** A signed DMG build pipeline (`app/make-dmg.sh`) with a drag-to-Applications
  layout, prints a SHA-256, and is wired for Developer ID signing + notarization once enrolled.

### Known limitations

- Builds are **self-signed, not yet notarized** — first launch needs right-click → Open (Apple
  Developer Program enrollment pending).
- App Intents may not auto-surface in Spotlight/Shortcuts (SwiftPM doesn't run Apple's intents
  metadata extractor); the URL scheme and hotkey work regardless.
- No Whisper model-size picker yet; the default model is used.

[0.1.0]: ../../releases/tag/v0.1.0
