# Changelog

All notable changes to Kleoth are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Short dictations and chat messages are pasted as heard.** The OpenRouter clean-up call now
  runs only when it earns its latency: dictations of fewer than 24 words, and every dictation into
  a messenger (Telegram, Slack, Discord, Teams, WhatsApp, Messages, Linear), paste Scribe's
  transcript directly — `no_verbatim` already strips fillers, so a casual one-liner arrives ~1 s
  sooner with no LLM in the loop and no risk of a rewrite. Longer dictations into editors, AI
  chats, notes, mail and browsers are still cleaned up and structured. Settings → Dictation →
  "Also clean up short dictations and chat messages" restores the old always-polish behavior
  (Keychain `dictation_polish_always`). Skipped rows show an "As heard" badge in the Dictations
  detail pane (not the orange "Raw" fallback — nothing failed).

## [0.2.0] — 2026-09-03

### Added

- **Dictation (hold fn+shift, speak, release).** System-wide voice typing: the utterance is
  transcribed by ElevenLabs Scribe (`scribe_v2`, `no_verbatim`, your personal-dictionary terms
  as keyterms), cleaned up by ONE short OpenRouter "polish" call (fillers/self-corrections removed,
  never translated — falls back to the raw transcript within 8 s if the model is slow, blocked, or
  changes the language), and pasted into whatever app has keyboard focus via the clipboard + a
  synthetic ⌘V; your previous clipboard is restored 0.5 s later. Double-tap for hands-free, tap
  once to stop, Esc cancels. A small dark pill rests half-tucked into a screen edge (bottom by
  default; drag it along the edge, or toward another edge to dock it there — side edges stand it
  up) and springs out while you speak: a live waveform while listening, a travelling wave while
  transcribing and polishing, a check when the text has landed, words only for warnings and
  errors. Silence just puts it back. Text-only history lands in `~/Kleoth/dictations/<day>.json` and is
  browsable from the new **Dictations** scope in the History window; a personal dictionary lives
  in `~/.config/kleoth/dictionary.json` (Settings → Dictation). Audio is never kept. Opt-in
  (Settings → Dictation) and requires the **Accessibility** permission (for the hotkey and the
  paste); `dictate` is a headless CLI probe for the pipeline.
- **Polish adapts to where you're typing.** In composition surfaces — AI chats (Claude, ChatGPT,
  Cursor…), editors, notes, documents, mail, browsers — the polish step restructures spoken
  brainstorming into the text you would have typed: ideas reordered, fragments merged, spoken
  lists rendered as lists, the word you settled on kept, thinking-out-loud dropped, every point
  preserved and nothing invented. Messaging apps get a light touch that keeps your sentence order
  and voice; terminals get plain single-line text. The spoken language is always kept, including
  Russian sentences with English technical terms.

- **Choose the engine per meeting.** An untranscribed recording's detail pane now offers
  both **Transcribe** (free, on-device) and **Transcribe in cloud** (ElevenLabs Scribe, your
  key) side by side.
- **Per-tier transcript variants.** Re-transcribing a meeting with the other engine keeps the
  previous transcript + summary as a variant instead of overwriting it — switch between the
  On-device and Cloud versions from the tier badge in the meeting detail view.
- **Folder sizes.** Meeting rows, the detail view, and multi-selection now show each meeting's
  size on disk, and Settings totals your `~/Kleoth` footprint.
- **Remove Transcription.** Revert a meeting to its saved audio — the transcript, summary, and
  any variants move to the Trash (recoverable) while the recording, title, and speaker names
  stay, ready to re-transcribe. Available from the History context menu (multi-select works)
  and the detail toolbar.
- **Failed runs now explain themselves where you're looking.** When a transcription or
  summarization fails (e.g. an ElevenLabs payment/quota issue), the meeting keeps a visible
  record of it: a dismissible error card in the meeting detail view and a red "Failed" chip on
  its History row (hover for the message). Previously the error appeared only in the menu-bar
  popover's status line, so from the History window a failed cloud transcription just silently
  reverted to *Untranscribed*. Retrying, dismissing, or trashing the meeting clears it.

### Changed

- **Default summary model is now `z-ai/glm-5.3-flash`** (was the retired
  `google/gemini-3-flash-preview`). The dictation polish model defaults to
  `google/gemini-3.5-flash-lite` (median ~0.9 s per dictation in live measurements, vs 3–4 s on
  GLM) and falls through to `z-ai/glm-5.3-flash` when the primary is unreachable. A stored
  retired slug is migrated in memory on every launch and rewritten in the Keychain the first time
  Settings opens. Why not Gemini: accounts whose OpenRouter privacy settings enforce Zero Data
  Retention find every `google/*` model blocked (404 `zdr-violation-by-account`), while GLM works
  under both the no-train and ZDR guardrails. `google/gemini-3.8-flash` remains selectable in the
  picker — relax the guardrail at openrouter.ai/settings/privacy to use it.
- Cloud transcription (Scribe) requests for dictation send `no_verbatim=true` (fillers dropped
  server-side); meeting transcription is unchanged.
- **Transcription after recording is now opt-in.** Stopping a recording saves the audio and
  lists it as *Untranscribed*; transcription starts only when you choose an engine on the
  meeting (or turn on "Transcribe automatically after recording" in Settings). This applies to
  existing installs too — flip the new toggle to restore the old always-transcribe behavior.

### Fixed

- **Playback now plays both sides in both ears.** The built-in player live-downmixes the
  2-channel meeting file (your mic on the left, the other side on the right), so you no longer
  hear yourself only in the left ear. The file on disk keeps its channel layout.
- Over-amplified microphone peaks are now clamped during loudness normalization, preventing
  hard clipping in future recordings' combined audio.
- Summaries are no longer silently truncated: completions cut off at the output
  cap (`finish_reason == "length"`) are retried with a larger budget and a
  truncated result is surfaced as a failure rather than shipped half-empty.
- The onboarding "Start your first recording" button no longer no-ops after
  "Skip setup" — it routes to the permissions step so consent is acknowledged.

### Removed

- **Slack integration.** The Slack webhook export is gone — the `kleoth slack`
  CLI subcommand, the Settings webhook field, the "Post to Slack" Shortcut /
  App Intent, the `kleoth://slack-latest` URL verb, and the detail view's "Copy
  for Slack" action (replaced by a Slack-free **Copy Summary** that copies the
  rendered Markdown).

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

[0.2.0]: ../../releases/tag/v0.2.0
[0.1.0]: ../../releases/tag/v0.1.0
