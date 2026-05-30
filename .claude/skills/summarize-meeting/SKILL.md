---
name: summarize-meeting
description: Summarize a Kleoth meeting transcript locally with Claude Code — produces summary.json (the MeetingSummary schema) and summary.md with no OpenRouter key and zero API cost. Use when the user wants to summarize a Kleoth meeting directory (or transcript) without paying for an LLM API.
---

# Summarize a Kleoth meeting (free, no API key)

This is the no-cost summarization path for Kleoth. Instead of calling OpenRouter (the GPT‑4.1 mini path in `kleoth summarize`), **you — Claude Code — read the transcript and write the summary directly**. The output is interchangeable with the paid path: the same `summary.json` schema and a `summary.md` rendered by the `kleoth` CLI.

## Input

A **meeting directory** produced by `kleoth transcribe` (it contains `transcript.json`, `transcript.md`, and `meta.json`). The directory path is the argument to this skill. If none was provided, ask the user which meeting directory to summarize.

## Steps

1. **Read the transcript.** Read `<dir>/transcript.md` (speaker‑tagged `Name: text` lines). If it is missing, read `<dir>/transcript.json` (the raw ElevenLabs response) and reconstruct the dialogue from its `words[]` / `transcripts[]` + `speaker_id`. Read `<dir>/meta.json` for the title, date, and participants.

2. **Summarize**, following the same rules as Kleoth's `Summarizer`:
   - Be precise and factual. **Do not invent information.** If something is ambiguous, say so.
   - Use the exact participant/speaker names that appear in the transcript.
   - Include an action item only if a concrete task was stated or clearly implied. If the owner is unstated use `"unassigned"`; if the due date is unstated use `null`.

3. **Write `<dir>/summary.json`** with the Write tool — valid JSON, **snake_case keys exactly as below** (this is what `MeetingStore` and `kleoth render` expect). No prose, no markdown fences:
   ```json
   {
     "tldr": "3–4 sentence overview",
     "decisions": ["clear decision statements"],
     "action_items": [{ "owner": "name or 'unassigned'", "task": "...", "due": "date or null" }],
     "key_points": ["bulleted discussion points"],
     "per_speaker_highlights": [{ "speaker": "name", "highlights": ["..."] }],
     "open_questions": ["unresolved items"],
     "suggested_tags": ["topic tags"]
   }
   ```

4. **Render `summary.md`** by running the CLI (deterministic, no API call — formatting then matches the paid path exactly):
   ```sh
   swift run kleoth render <dir>          # add --no-transcript to omit the transcript appendix
   ```
   If the binary isn't built yet, run `swift build` first.

5. **Report**: tell the user the summary was produced with Claude Code at **$0.00 API cost**, and print the path to `summary.md`.

## Notes

- This path needs **no `OPENROUTER_API_KEY`** — it uses your Claude Code session.
- It is interchangeable with `kleoth summarize` (OpenRouter / GPT‑4.1 mini); both write the same `summary.json` + `summary.md`.
- Never read or echo `.env` or any API keys.
