# Bot-free meeting recorder for Mac: a local, open-source alternative to Granola, Otter, Fireflies and tl;dv

Kleoth records your meetings directly on your Mac: your microphone and the other participants'
audio, from Zoom, Google Meet, Microsoft Teams, a browser tab or anything else that plays sound.
No bot joins the call. It transcribes on device with Whisper and writes the transcript and an
AI summary as plain Markdown and JSON files in `~/Kleoth`. There is no account and no Kleoth
server. It is free and open source (Apache-2.0).

**[⬇ Download Kleoth](https://github.com/ofcRS/kleoth/releases/latest)** · macOS 14.4+ ·
[Back to the README](../README.md)

<p align="center">
  <img src="assets/demo-meeting.gif" alt="The History window: a meeting's TL;DR and summary, its action items with owners and due dates, per-speaker highlights, then the next meeting" width="720">
</p>

## How it works

1. **Record.** Click **Start Recording** in the menu bar, press your global hotkey, or use
   `kleoth://record` from a script or Raycast. Kleoth records two tracks: your mic, and the audio
   your Mac plays (through a Core Audio process tap, macOS 14.4+). The first time you record, a consent
   notice asks you to confirm that everyone agrees; the acknowledgement is stamped into each
   meeting's `meta.json`.
2. **Transcribe.** On device by default, with Whisper large-v3 turbo through
   [WhisperKit](https://github.com/argmaxinc/WhisperKit) on the Apple Neural Engine. It is free,
   offline after a one-time ~600 MB model download, and needs no key. The language is detected
   automatically (English, Russian and dozens more), or pinned in Settings. Transcribing on stop is
   opt-in. Otherwise you choose per meeting: **Transcribe** (on device) or **Transcribe in cloud**
   ([ElevenLabs Scribe](https://elevenlabs.io), your key). Doing both keeps both versions, and you
   switch between them.
3. **Know who said what.** Your mic and the system audio are separate channels, so "You" and "Them"
   need no guesswork. Rename a speaker to a real name and the summary's action items and highlights
   follow.
4. **Summarize.** A TL;DR, an overview, action items and per-speaker highlights, written in the
   meeting's own language. The summary runs right after each transcription, on your AI provider:
   Claude Code, Codex, a local Ollama or LM Studio server, or OpenRouter. On Automatic, the
   default, that is the first one Kleoth finds (see [AI providers](ai-providers.md)). A summary is
   saved only when it is complete. One that comes back cut off or with a section missing is
   retried once. If it's still incomplete, the meeting shows "Summary failed" with the reason and
   a **Summarize** button to try again. It is never saved half-empty.
5. **A cover, if you want one.** Off by default. With covers on, each summarized meeting gets a
   picture across the top of its page, cute animals or everyday objects acting out what it was
   about; click it to see it full size. See [Meeting covers](../README.md#meeting-covers).

## Your meeting is a folder

```
~/Kleoth/meeting-2026-09-24-143000/
  mic.m4a · system.m4a · meeting.m4a   your audio (mic, system, 2-channel combined)
  transcript.json · transcript.md       the transcript
  summary.json · summary.md             the summary
  speakers.json                         speaker_0 / speaker_1 → names
  meta.json                             duration, engine, timestamps, consent
  cover.jpg · cover.json                the cover and how it was drawn (if covers are on)
```

Grep it, sync it with anything, open it in Obsidian, delete it. The app is a view over the
directory. The `kleoth` CLI (`transcribe`, `summarize`, `rename`, `render`, `illustrate`) works on the same
folders, and so do the Raycast extension and the `kleoth://` URL scheme.

## Compared with hosted meeting recorders

- **Otter, Fireflies and tl;dv** are built around a notetaker that joins the call as a participant,
  and the recording lives in their cloud. Kleoth never joins the call: it records what your Mac
  hears, and the files stay on your disk.
- **Granola** records from your Mac without a bot too, but it is a hosted service: you sign in, and
  your notes live in its cloud. Kleoth is the local, open-source version of that idea: no account,
  and transcription on device.
- What the hosted tools have that Kleoth doesn't: shared team workspaces, CRM integrations,
  Windows and mobile apps. Kleoth is a single-user Mac app, on purpose.

## What leaves your Mac

- **Recording and on-device transcription** stay on your Mac. The only network use is the
  one-time model download.
- **Cloud transcription**, if you click it: the meeting's audio goes to ElevenLabs Scribe with your key.
- **Summaries**: after each transcription, the transcript goes to your AI provider. On Automatic
  that is the first one found (local server, Claude Code, Codex, OpenRouter). With no local server
  running and the Claude Code or Codex CLI signed in, that means Anthropic's or OpenAI's servers,
  under your account. To keep transcripts on the Mac, pick a local server in Settings → Accounts.
- **Covers**, if you turn them on: your AI provider writes a one-sentence scene from the summary,
  and only that scene goes to the image engine you pick: to OpenAI through Codex, or to
  OpenRouter. A local image server keeps it on your Mac.

## Consent

Recording a conversation is regulated, and many places require every participant's consent. Kleoth
records without a visible bot, which is a UX choice, not legal cover. Ask first. The app shows a
consent notice and records your acknowledgement in each meeting's `meta.json`.

## Related

- [Dictation](dictation.md): Wispr Flow-style voice typing, from the same app.
- [Screen recording](screen-recording.md): Loom-style, local (beta).
- [AI providers](ai-providers.md): which models write your summaries and what each needs.

If Kleoth is useful to you, [starring the repo](https://github.com/ofcRS/kleoth) helps other Mac
users find it.
