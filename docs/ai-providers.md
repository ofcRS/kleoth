# Bring your own AI to Kleoth: Claude Code, Codex, Ollama, LM Studio, OpenRouter or Apple on-device

Kleoth doesn't sell you another AI subscription. Its two language-model jobs, **meeting
summaries** and **dictation clean-up**, run on whatever you already use:

- the Claude Code or Codex CLI you're signed into
- a local Ollama or LM Studio server
- your own OpenRouter key
- Apple's on-device model

Speech-to-text is separate: Whisper on your Mac, or ElevenLabs Scribe with your key. With no AI
provider at all, Kleoth still records and transcribes. You just get no summaries, and dictations
are pasted as heard.

**[⬇ Download Kleoth](https://github.com/ofcRS/kleoth/releases/latest)** · macOS 14.4+ ·
[Back to the README](../README.md)

## Language models

| Provider | What it needs | Summaries | Dictation clean-up |
|---|---|---|---|
| **Local server**: Ollama, LM Studio, any OpenAI-compatible URL | the server running (default `http://localhost:11434/v1`) | ✓ | ✓ |
| **Claude Code** | the `claude` CLI installed and signed in | ✓ | ✓ (a few seconds per clean-up) |
| **Codex** | the `codex` CLI installed and signed in | ✓ | — |
| **OpenRouter** | an API key; any model on openrouter.ai | ✓ | ✓ |
| **Apple on-device** | macOS 26 with Apple Intelligence on | — | ✓ |

**Automatic** (the default, in Settings → Accounts → AI provider) picks, per job, the first one
available in that order: local server → Claude Code → Codex → OpenRouter → Apple. Pick one yourself
and Kleoth uses it; a pick that can't do a job (Codex for dictation, Apple for summaries) falls
through the same order for that job only. The summary and clean-up models are chosen on the
Meetings and Dictation pages of Settings, from the models the provider actually offers.

### Claude Code and Codex: use the subscription you already pay for

Kleoth runs the `claude` or `codex` binary you installed, signed in with your own account. It never
reads, stores or passes on a token. Claude Code is called in isolation: no settings, no
`CLAUDE.md`, no MCP servers, no tools, and Kleoth's own system prompt. That keeps each call's
overhead to a few thousand tokens instead of the ~150k a default session loads, and it can't
touch your files. Kleoth
records these calls as free, because your subscription covers them.

From the command line: `kleoth summarize <meeting-dir> --provider claude-code` (or `codex`, `local`,
`openrouter`). Inside Claude Code, the repository's `summarize-meeting` skill writes the same
`summary.json` and `summary.md` from your session.

### Local servers: nothing leaves the machine

Point Kleoth at Ollama, LM Studio or any OpenAI-compatible `/v1` URL; a key is optional. Long
meetings need a bigger context than Ollama's default, which can be as small as 4096 tokens. Start
it with `OLLAMA_CONTEXT_LENGTH=32768 ollama serve`, or, for the Ollama app, run
`launchctl setenv OLLAMA_CONTEXT_LENGTH 32768` and restart it. Ollama's `/v1` endpoint cannot
set the context per request, and it reportedly drops the start of an over-long prompt without an
error.

### OpenRouter

Any model slug works. The summary default is `z-ai/glm-5.3-flash`, and the dictation default is
`google/gemini-3.5-flash-lite` (about 0.9 s), falling back to GLM. If your account blocks
providers that train on data or enforces Zero Data Retention, some families return 404s. GLM works
under both guardrails.

### Apple on-device

Dictation clean-up only, on macOS 26 with Apple Intelligence turned on in System Settings. Fast
and fully local, with a small context, which is why it doesn't do summaries.

## Speech-to-text

| Engine | Where it runs | Used for | Needs |
|---|---|---|---|
| **Whisper large-v3** via [WhisperKit](https://github.com/argmaxinc/WhisperKit) | on your Mac (Apple Neural Engine) | meetings, screen recordings, retrying a failed dictation | a one-time ~600 MB download |
| **[ElevenLabs Scribe](https://elevenlabs.io)** | ElevenLabs' cloud, with your key | live dictation; meetings and recordings you send to the cloud | an API key with the `speech_to_text` permission |

## What goes where

- **Audio** goes only to ElevenLabs Scribe, only with your key, and only for a dictation or a
  cloud transcription you asked for.
- **Transcripts** go only to the language-model provider you chose, for a summary or a clean-up.
  A local server or Apple's model keeps them on the machine.
- **Nothing goes to Kleoth.** There is no Kleoth server, account or telemetry.

## Related

- [Dictation](dictation.md) · [Meetings](meetings.md) · [Screen recording](screen-recording.md)

If Kleoth is useful to you, [starring the repo](https://github.com/ofcRS/kleoth) helps other Mac
users find it.
