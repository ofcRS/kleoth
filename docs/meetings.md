# Bot-free meeting recorder for Mac: a local, open-source alternative to Granola, Otter, Fireflies and tl;dv

Kleoth records your meetings directly on your Mac: your microphone and the other participants'
audio, from Zoom, Google Meet, Microsoft Teams, a browser tab or anything else that plays sound.
No bot joins the call. It transcribes on device with Whisper and writes the transcript and an
AI summary as plain Markdown and JSON files in `~/Kleoth`. There is no account and no Kleoth
server. It is free and open source (Apache-2.0).

**[⬇ Download Kleoth](https://github.com/ofcRS/kleoth/releases/latest)** · macOS 14.4+ ·
[Back to the README](../README.md)

## How it works

1. **Record.** Click **Start Recording** in the menu bar, press your global hotkey, or use
   `kleoth://record` from a script or Raycast. Kleoth records two tracks: your mic, and the audio
   your Mac plays (through a Core Audio process tap, macOS 14.4+). A small "Before you record" notice
   asks you to confirm that everyone consents, and the acknowledgement is stamped into the meeting.
2. **Transcribe.** On device by default, with Whisper large-v3 through
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
   meeting's own language. The summary runs on the AI you already use: Claude Code, Codex, a local
   Ollama or LM Studio server, or OpenRouter (see [AI providers](ai-providers.md)). A summary is
   saved only when it is complete. One that comes back cut off or with a section missing is retried
   once, and otherwise reported as failed, never saved half-empty.

## Your meeting is a folder

```
~/Kleoth/meeting-2026-09-24-143000/
  mic.m4a · system.m4a · meeting.m4a   your audio (mic, system, 2-channel combined)
  transcript.json · transcript.md       the transcript
  summary.json · summary.md             the summary
  speakers.json                         speaker_0 / speaker_1 → names
  meta.json                             duration, engine, timestamps, consent
```

Grep it, sync it with anything, open it in Obsidian, delete it. The app is a view over the
directory. The `kleoth` CLI (`transcribe`, `summarize`, `rename`, `render`) works on the same
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

- **By default, nothing.** Recording and on-device transcription never touch the network.
- **Cloud transcription**, if you click it: the meeting's audio goes to ElevenLabs Scribe with your key.
- **Summaries**: the transcript goes to the AI provider you picked. A local server keeps it on the
  machine. Claude Code and Codex use the account you're already signed in with.

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
