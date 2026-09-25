# Loom-style screen recording on macOS, local and open source (beta)

Kleoth records your screen, or a region of it, with system audio and your microphone in one small
MP4 that stays on your Mac. Afterwards it transcribes the recording on device with word timings.
The viewer plays the video with the transcript beside it: the word being spoken is highlighted, and
clicking a word jumps to it. Nothing is uploaded, and there is no account. It is part of Kleoth,
a free, open-source (Apache-2.0) Mac app.

**Status: beta.** The viewer is a first cut: **no trimming, no sharing, no
export yet.** If you need a link to send someone, Loom still does that and Kleoth doesn't.

**[⬇ Download Kleoth](https://github.com/ofcRS/kleoth/releases/latest)** · macOS 14.4+ ·
[Back to the README](../README.md)

<p align="center">
  <img src="assets/demo-screen.gif" alt="Click Record in the pill; it becomes a toolbar with a timer and audio meters; click Stop and the recording is saved" width="720">
</p>

## How it works

1. **Start.** Pick "Record screen…" in the menu-bar popover, or hover the pill at the edge of your
   screen (shown while dictation is on) and click **Record**.
2. **Pick what to record.** The screen dims. Drag a region, or press Return for the whole display.
   Esc cancels. Kleoth's own windows (the pill, the picker, the toolbar) are never in the frame.
3. **Record.** The pill becomes a toolbar with the elapsed time and live meters for your mic and
   the system audio. Only its **Stop** button stops, so a stray click can't end a recording. You
   can dictate mid-recording.
4. **Stop.** The file lands in `~/Kleoth/screen-recordings/` as an H.264 MP4, at most 1920 px on the
   long edge and 30 fps, about 22 MB per minute. System audio and mic are mixed into one track. Quitting
   mid-recording asks first and still saves the file. A recording interrupted by a crash is
   recovered on the next launch.
5. **Read it.** Each recording is transcribed on device right after it is saved. In History →
   Recordings, the viewer shows the transcript beside the video. The current word is highlighted,
   clicking a word seeks, and double-clicking a word or the title corrects it. Older recordings
   can be transcribed on device or in the cloud from the viewer.

<p align="center">
  <img src="assets/demo-viewer.gif" alt="The recordings viewer: a narrated slide recording plays on the left while the transcript on the right highlights each word as it is spoken" width="720">
</p>

## Your recording is two files

```
~/Kleoth/screen-recordings/
  screen-2026-09-24-143000.mp4    the movie, never modified after it is written
  screen-2026-09-24-143000.json   title + the word-timed transcript
```

Editing a word in the viewer rewrites only the `.json` file. The movie is yours to send, upload,
or cut in any editor.

## What leaves your Mac

Nothing by default: recording and on-device transcription are local. If you choose cloud
transcription for a recording, its audio goes to ElevenLabs Scribe with your key.

## Set up

Kleoth asks for the **Screen Recording** permission the first time you record the screen, and
uses the microphone you picked in Settings → Microphone.

## Limits (why it's a beta)

- No trimming, sharing links or export presets.
- No webcam bubble, no drawing on screen, no live captions.
- Recordings are written as fragmented MP4 (so a crash loses at most the last ten seconds or so), and not every
  player has been checked with that. If a file won't open somewhere, please
  [open an issue](https://github.com/ofcRS/kleoth/issues).

## Related

- [Dictation](dictation.md): Wispr Flow-style voice typing, from the same app.
- [Meetings](meetings.md): bot-free meeting recording and notes.
- [AI providers](ai-providers.md): bring your own AI, or none.

If Kleoth is useful to you, [starring the repo](https://github.com/ofcRS/kleoth) helps other Mac
users find it.
