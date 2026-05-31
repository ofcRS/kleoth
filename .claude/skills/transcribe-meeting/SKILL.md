---
name: transcribe-meeting
description: Transcribe a Kleoth meeting from within Claude Code by running the `kleoth transcribe` CLI (ElevenLabs Scribe) with the right flags, then reporting the diarized transcript and its cost. Use when the user wants to turn a meeting recording — an audio file or a meeting/recording folder — into a speaker-tagged transcript. Note: unlike summarization, Claude cannot do speech-to-text itself; this wraps the paid Scribe API and needs the user's own ElevenLabs key.
---

# Transcribe a Kleoth meeting (wraps `kleoth transcribe`)

This skill turns a meeting recording into a **diarized, speaker‑tagged transcript** by driving the `kleoth transcribe` CLI for the user, picking the correct flags, and reporting the result and its cost.

> **Why this isn't free (unlike summarize-meeting).** Summarization is a language task, so the `summarize-meeting` skill lets *you — Claude Code* — do it directly at $0.00. **Transcription is speech‑to‑text, which Claude cannot do itself.** It requires the **ElevenLabs Scribe** API, which is **paid and uses the user's own key**. This skill's value is convenience: it points Scribe at the right file with the right flags, then surfaces the transcript and cost — it does not (and cannot) transcribe audio on its own.

## When to use

- The user has an **audio file** (`.m4a`, `.wav`, `.mp3`, `.flac`, …) and wants a transcript.
- The user points at a **meeting folder** produced by the Kleoth macOS app (named `meeting-YYYY-MM-DD-HHMMSS`, containing `mic.m4a` / `system.m4a` / `meeting.m4a`) and wants it transcribed.
- The user says "transcribe this meeting / call / recording" and wants speaker‑separated text out.

If they want a *summary*, transcribe first (this skill), then hand off to **`summarize-meeting`** (see below).

## Prerequisite: the user's ElevenLabs key (BYO, paid)

The CLI reads `ELEVEN_API_KEY` (or `ELEVENLABS_API_KEY`) from the environment, a `.env` file, or `~/.config/kleoth/config.json`. The key **must have the `speech_to_text` permission** — without it Scribe returns `401 {"status":"missing_permissions"}` even though auth otherwise succeeds.

- **Never read, print, or echo `.env` or any API key.** If the CLI reports a missing/invalid key, tell the user how to set one (env / `.env` / `~/.config/kleoth/config.json`) and the `speech_to_text` requirement — don't try to fish the key out yourself.
- This is a billed call against the user's account. Cost scales with audio length (~$0.22/hour of audio). For a long recording, it's polite to confirm before running.

## Input: pick the file and the mode

Ask for the input if none was given. There are two shapes, and they need **different flags**:

1. **A single mixed audio file** (one track, everyone audible on it) → use **diarization**: Scribe separates speakers into `speaker_0`, `speaker_1`, … Pass `--num-speakers N` when the count is known (better accuracy); omit it to let Scribe guess. **Do not** pass `--multi-channel`.

2. **A Kleoth meeting/recording folder** (mic + system audio) → use **multi‑channel**: one speaker per channel, giving clean "you vs. them" separation. The folder contains a pre‑built 2‑channel `meeting.m4a` (mic = ch 0, system = ch 1); transcribe **that file** with `--multi-channel`. If only `mic.m4a` is present (the 2‑channel build didn't happen), fall back to treating it as a single mixed file (option 1). `kleoth transcribe` takes a **single file argument**, so always point it at `meeting.m4a` inside the folder — not at the folder itself.

Build the CLI first if needed: `swift build`.

## Exact invocations

**Single mixed file (diarized):**
```sh
swift run kleoth transcribe /path/to/meeting.m4a --num-speakers 2
#   --num-speakers N   hint the speaker count (omit to auto-detect)
#   --language en      hint a language (auto-detected when omitted)
#   --out ./out        output directory (default: ~/Kleoth)
```

**A mic+system meeting folder (multi-channel):**
```sh
swift run kleoth transcribe "/path/to/meeting-YYYY-MM-DD-HHMMSS/meeting.m4a" --multi-channel
#   one speaker per channel — do NOT also pass --num-speakers
```

The command writes a fresh, uniquely-named meeting directory (default `~/Kleoth/meeting-<timestamp>/`, or under `--out`) containing `transcript.json` (raw Scribe response), `transcript.md` (speaker‑tagged `Name: text` lines), and `meta.json` (includes the cost breakdown). It **does not** produce a summary — that's a separate step.

> Each run gets its own timestamped folder, so transcribing twice never overwrites an earlier transcript.

## Surface the result and the cost

On success the CLI prints up to ~20 speaker turns, a `Cost:` line, and `Meeting saved to: <dir>`. Report back:

- **Where it landed** — the meeting directory path and that `transcript.md` holds the full diarized transcript.
- **The cost** — read it from `<dir>/meta.json` rather than re‑deriving it. The `cost` object uses snake_case: `transcription_cost` (USD; the billed amount), `summary_cost` (0 here — no summary was made), and `audio_duration_secs`. Quote the transcription cost and the audio length, e.g. *"Transcribed 53.7s of audio for ~$0.0033 (ElevenLabs Scribe)."* Be clear this was a **real, paid** API call on the user's key.
- **Speakers are anonymous** (`speaker_0`, `speaker_1`, …). If they want real names, point them at `swift run kleoth rename <dir>` (interactive — shows sample turns per speaker).

## Hand off to summarize-meeting

Transcription only produces the transcript. If the user wants decisions / action items / a TLDR, offer to continue with the **`summarize-meeting`** skill, passing it the **meeting directory** this skill just produced. That path is free (no OpenRouter key, $0.00) — *you* write `summary.json` + `summary.md` directly. So the natural flow is: **this skill (paid Scribe transcript) → `summarize-meeting` (free Claude Code summary)**, ending with both `transcript.md` and `summary.md` in the same folder.

## Notes

- Equivalent to the macOS app's record→transcribe path and to the transcription half of `kleoth summarize` — all share the same pipeline and write the same artifacts.
- For a summary in one shot via the *paid* model instead, `kleoth summarize <file>` transcribes and summarizes together (needs both an ElevenLabs **and** an OpenRouter key). Prefer transcribe + `summarize-meeting` to keep the LLM half free.
- Never read or echo `.env` or any API keys.
