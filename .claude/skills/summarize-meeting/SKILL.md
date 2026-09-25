---
name: summarize-meeting
description: Summarize a Kleoth meeting in this Claude Code session — you read the transcript and write summary.json (the MeetingSummary shape) and summary.md yourself, with no API key and no API cost. Use when the user wants a Kleoth meeting directory summarized here, by you, rather than through one of Kleoth's AI providers.
---

# Summarize a Kleoth meeting in this session

Kleoth normally summarizes through an AI provider: the app does it after each transcription, and
the CLI does it with `kleoth summarize <dir> --provider openrouter|local|claude-code|codex`. This
skill is the in-session alternative: **you — Claude Code — read the transcript and write the
summary directly**. The output is interchangeable with the provider path: the same `summary.json`
shape, and a `summary.md` rendered by the `kleoth` CLI.

## Input

A **meeting directory** written by the Kleoth app or by `kleoth transcribe`
(`meeting-yyyy-MM-dd-HHmmss/`, containing `transcript.md` and `meta.json`). The directory path is
the argument to this skill. If none was provided, ask the user which meeting to summarize.

If the meeting has no transcript yet (no `transcript.md`, or no `meta.json`: the app shows it as
*Untranscribed*), stop and say so: transcribe it first, in the app or with the
`transcribe-meeting` skill.

## Steps

1. **Read the transcript.** Read `<dir>/transcript.md` (speaker-tagged `Name: text` lines). If it
   is missing but `<dir>/transcript.json` exists, reconstruct the dialogue from its `words[]` /
   `transcripts[]` and `speaker_id`. Read `<dir>/meta.json` for the title, date and participants,
   and `<dir>/speakers.json` (if present) for the display names.

2. **Summarize**, following the same rules as Kleoth's `Summarizer`:
   - Write every value (title, tldr, overview, each task, each highlight) in the **same language
     as the transcript**. Don't translate it into English or anything else.
   - Keep speaker and owner names exactly as they appear in the transcript.
   - Be precise and factual. **Do not invent information.** If something is ambiguous, say so.
   - Include an action item only if a concrete task was stated or clearly implied. If the owner is
     unstated use `"unassigned"`; if the due date is unstated use `null`.

3. **Write `<dir>/summary.json`** with the Write tool: valid JSON, **snake_case keys exactly as
   below** (what `MeetingStore` and `kleoth render` read), every key present. No prose, no
   markdown fences:
   ```json
   {
     "title": "a concise, specific 4-8 word meeting title",
     "tldr": "2-4 sentences capturing the essence of the meeting",
     "overview": "a detailed, faithful account of the whole meeting as flowing prose in several paragraphs separated by blank lines (no bullets, no headings): what was discussed and in what order, the context and reasoning, concrete specifics (names, numbers, dates, agreements and who made them), and how things were left",
     "action_items": [{ "owner": "name or \"unassigned\"", "task": "...", "due": "date or null" }],
     "per_speaker_highlights": [{ "speaker": "name", "highlights": ["their most important statements, positions and commitments"] }]
   }
   ```
   `action_items` may be an empty array; the other values may not be blank.

4. **Record who wrote it.** In `<dir>/meta.json`, set `"summary_provider": "claude-code"` and
   remove `"model"`, so the meeting doesn't credit an earlier model with this summary. Leave every
   other field as it is.

5. **Render `summary.md`** with the CLI (no API call, so the formatting matches the provider path
   exactly):
   ```sh
   swift run kleoth render <dir>          # add --no-transcript to omit the transcript appendix
   ```
   If the binary isn't built yet, run `swift build` first.

6. **Report**: tell the user the summary was written in this Claude Code session at no API cost,
   and print the path to `summary.md`.

## Notes

- No API key is needed; this uses your Claude Code session.
- `kleoth summarize <dir> --provider claude-code` gets a summary from Claude Code without this
  session: it runs `claude -p` in isolation and writes the same files.
- Never read or echo `.env` or any API key.
