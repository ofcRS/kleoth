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

1. **Record.** Click **Start Recording** in the menu bar, hover the pill at the edge of your screen
   (shown while dictation is on) and click **Meeting**, press your global hotkey, use
   `kleoth://record` from a script or Raycast, or click **Record** when the pill asks at the start
   of a call ([call detection](#calls-that-ask-to-be-recorded), off by default). Kleoth records two
   tracks: your mic, and the audio your Mac plays (through a Core Audio process tap, macOS 14.4+).
   The first time you record, a consent notice asks you to confirm that everyone agrees; the
   acknowledgement is stamped into each meeting's `meta.json`. However the meeting started, the pill
   shows its bar while it records, even with dictation off: the elapsed time, a meter for your mic
   and one for the system audio, and **Stop**. A system meter that stays flat while others talk
   means Kleoth isn't allowed to record system audio (*Privacy & Security → Screen & System Audio
   Recording*). Stopping shows "Meeting saved" for a few seconds; click it to open the meeting in
   History.
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

## Calls that ask to be recorded

Off by default. Turn on **Offer to record calls** in Settings → Meetings, and when another app
starts using the microphone, the pill asks:

- **"Zoom call — record it?"**, with **Record**, **Never for Zoom** and ✕. Call apps (Zoom, Teams,
  FaceTime, Webex) are asked about after 5 seconds, Google Meet and other calls in a browser after
  8, chat apps (a Slack huddle, Discord, Telegram) after 30, and any other app, or a browser where
  no call was seen, after a minute. With calendar access, an offer for a call (a call app, a call in a
  browser, or a chat-app huddle during an event with other people or a link) names the event on now:
  "“Weekly sync” on Zoom — record it?".
- **Nothing is recorded until you click Record**, and the seconds of the call before the click are
  not captured. If you haven't acknowledged recording consent yet, the consent notice asks first.
- **✕, or no answer for 30 seconds**, means not for this call: no second offer while it lasts, and
  none for the same app within 10 minutes. **Never for Zoom** stops the offers for that app;
  Settings → Meetings lists every "Never for …" with **Remove**. "Never for Chrome" silences a
  browser's other uses of the microphone, such as voice typing; Google Meet and other calls in Chrome
  are still offered.
- **Never in the way.** No offer while a meeting or a screen recording runs, while the pill is
  hidden for an hour, or while you dictate (it comes back afterwards, if the call is still on).
  Dictation tools, voice memos, Siri and macOS Dictation are never offered.
- **When the call app lets go of the microphone** during a meeting, the pill suggests stopping once,
  20 seconds later: "Zoom released the mic — stop recording?". Kleoth never stops a recording on its
  own; a call can go on in the room after the app hangs up.

Kleoth only notices which apps are using the microphone; no audio is read, and no new permission is
asked for. With Screen Recording or Accessibility already allowed, it reads the call window's title
to tell a Meet tab from other sites; a title that names no meeting is never saved.

## Your meeting is a folder

```
~/Kleoth/meeting-2026-09-24-143000/
  mic.m4a · system.m4a · meeting.m4a   your audio (mic, system, 2-channel combined)
  transcript.json · transcript.md       the transcript
  summary.json · summary.md             the summary
  speakers.json                         speaker_0 / speaker_1 → names
  meta.json                             title, participants, timestamps, consent, engine, where it happened
  cover.jpg · cover.json                the cover and how it was drawn (if covers are on)
```

`meta.json` is written the moment a meeting stops, whether you transcribe it or not, and whether call
detection is on or off. So an untranscribed recording is already named — after its calendar event,
or "Recording · Zoom · Sep 24, 14:05" — and can be renamed. It also remembers where it happened: the
app, the service, how you started it, the calendar event (with calendar access), and a window title
only when that title named a meeting. When the calendar event had exactly one other person in it,
their name replaces "Them".

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
- **Summaries**: after each transcription, the transcript goes to your AI provider, with the meeting's
  title, date and participants (with calendar access: the event's other attendees, by name or, without
  one, by email address). On Automatic
  that is the first one found (local server, Claude Code, Codex, OpenRouter). With no local server
  running and the Claude Code or Codex CLI signed in, that means Anthropic's or OpenAI's servers,
  under your account. To keep transcripts on the Mac, pick a local server in Settings → Accounts.
- **Covers**, if you turn them on: your AI provider writes a one-sentence scene from the summary,
  and only that scene goes to the image engine you pick: to OpenAI through Codex, or to
  OpenRouter. A local image server keeps it on your Mac.
- **Call detection** sends nothing anywhere: which app holds the microphone, the matched window
  title and the calendar event are read on your Mac and kept in the meeting's `meta.json` (its title
  and participants also go with the transcript for the summary, above).

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
