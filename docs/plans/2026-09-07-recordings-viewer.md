# Recordings viewer + live recording toolbar (phase 2 of screen recording)

_2026-09-07. Follows `2026-09-06-screen-recording.md` (v1, merged). Proof-of-concept depth by the user's
choice: "not a full production app yet — I just want to see the recordings in the UI."_

## 1 The ask (user, verbatim intent)

1. The pill while recording is "ugly, small, non-responsive, not animated" — make it live, with a toolbar
   that shows what is going on.
2. It must respond better when the orientation changes or it is dragged left or right.
3. A UI for the transcription: play the video with the transcript beside it, see the current word, click a
   word to jump, edit a word; plus a list of the recorded videos.
4. (Done separately, commit 80b15f9) the popover rows are clickable across their whole frame.

Decisions taken with the user:
- **Recordings are NOT meetings.** They live in their own History scope ("Recordings"), like Dictations.
  No summary, no speaker split, no meeting folder. "They are just recordings, similar to Loom."
- **Transcription happens after the recording is saved** (not live subtitles), automatically, on the
  on-device engine, with word timestamps on. Cloud (Scribe) on demand from the viewer.
- Pause is out of this pass (offered, not requested).

## 2 Storage

`~/Kleoth/screen-recordings/` stays flat. Each finished `screen-<stamp>.mp4` may have a sidecar
`screen-<stamp>.json` (`ScreenRecordingFileNaming.sidecarURL`) = `ScreenRecordingRecord`
(snake_case, ISO-8601 dates, acronym-free keys): `schema_version`, `title?`, `duration_secs?`,
`language_code?`, `transcript_tier?` (`local-whisper` / `sota-scribe`), `transcript_model?`,
`transcribed_at?`, `transcript_error?`, `words: [{text, start, end}]`.

- No sidecar → untranscribed. Sidecar with `transcript_error` and no words → failed (retryable).
- Word and title edits are written back into the sidecar; the `.mp4` is never modified.
- `ScreenRecordingStore` lists a folder (`*.mp4` minus in-flight `.recording.mp4`; `-recovered.mp4`
  included), pairs sidecars, trashes both. `ScreenRecordingItem` is the list row (url, `recordedAt` from
  the stem, size, record, `transcriptState`). 7 core tests (`ScreenRecordingRecordTests`).

## 3 Transcription job (KleothApp, on `ScreenRecordingController`)

`transcribe(item, tier:)` → `RecordingController.enqueuePipelineJob` (shared FIFO — never two WhisperKit
engines) → `RecordingAudioExtractor.extractAudio` (AVAssetExportSession → `$TMPDIR/kleoth-recordings/
<stem>.m4a`, deleted after) → `LocalTranscriber(language:, wordTimestamps: true)` or `ScribeClient`
(diarize off) → `ScreenRecordingRecord.words(from:)` → sidecar. Failure → sidecar with
`transcript_error`. Auto-run with the local tier after `showSaved()`; recovered/old files only via
the viewer's buttons.

`LocalTranscriber.wordTimestamps` maps WhisperKit `segment.words` to one `ScribeWord` per word;
`false` (meetings) is byte-identical to before.

## 4 Viewer (History → Recordings)

`HistoryScope.recordings` → `RecordingsListView` (the `DictationsListView` pattern: day sections, search
over title + transcript, badges Untranscribed / Transcribing… / Failed, context menu Reveal / Trash) →
`RecordingDetailView(item:onSaveRecord:onTranscribe:isTranscribing:onReveal:onTrash:)`: AVKit player
left, transcript right as a `WordFlowLayout` of word buttons; `record.wordIndex(at: currentTime)`
(binary search, 10 Hz observer) highlights the current word and auto-scrolls; click = seek,
double-click = inline edit (Return commits via `onSaveRecord`, Esc cancels, empty removes); editable
title; toolbar Copy transcript / Reveal / Re-transcribe / Move to Trash. The popover's "Last screen
recording" row opens History on Recordings selecting that file.

## 5 Pill: the live recording toolbar (KleothPillUI)

`.recording(since:)` renders a horizontal bar: pulsing red dot · `mm:ss` · mic meter · system meter ·
explicit **Stop** button. Only Stop stops (`.stopScreenRecording`); the bar is the drag handle.
Levels: `ScreenRecorder.levels` (per-buffer RMS of each lane, stored in heap words) polled at 20 Hz by
the controller → `PillCoordinator.setRecordingLevels` → `DictationPillController.setRecordingLevels`
(normalized + smoothed like the dictation meter).

**Orientation rule:** `.recording/.saving/.saved`, and every dictation phase while the backdrop is
`.recording`, never rotate — on a left/right edge the bar lies flat against the edge, centered on the
anchor's along-edge fraction, clamped in bounds. The `.idle` sliver keeps standing up. An edge flip
mid-recording re-lays out without a sideways jump. Motion: the bar grows out of the edge on the existing
rise/morph beats; dot + meters on the animation clock; Reduce Motion → static.

## 6 Lanes

T0 (contract, b909a45) → L2 capture (levels, word timestamps, extractor + `screenrec` levels line) ∥
L3 pill (toolbar, orientation, sandbox films) ∥ L4 app (library, job, History scope, level pump,
popover hook) ∥ L5 viewer (`RecordingDetailView` + player model + flow layout). Integration: merge,
build, 346 core tests, films, release install; the user runs the end-to-end check (record → transcript
appears → Recordings → play / click / edit / relaunch).

## 7 Verification checklist (user)

1. Record 20 s while talking with music playing → the bar shows both meters moving, digits tick, Stop
   ends it; a stray click on the bar does nothing.
2. Drag the bar to the left edge mid-recording → it stays horizontal, hugs the edge; back to bottom.
3. fn+shift mid-recording on a side edge → the dictation capsule stays horizontal, returns to the bar.
4. History → Recordings: the new file shows "Transcribing…", then words; play → highlight follows; click a
   word → seeks; double-click → edit → Return → relaunch → the edit is still there.
5. An old recording → "Transcribe on device" → words. "Transcribe in cloud" → words (needs the key).
6. Move to Trash → both the `.mp4` and `.json` are in the Trash.
