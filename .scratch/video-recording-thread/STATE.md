---
title: video-recording-thread
kind: thread
summary: 'Loom-style screen recording (screen or region + mic + system audio, small H.264/AAC files) started/stopped from the dictation pill; workflow running 2026-09-06.'
---

# video-recording-thread — video recording for Kleoth · handoff state

**Hub:** [[INDEX]]
**Status:** 2026-09-07 — RELEASED as v0.3.0 (feat/recordings-viewer → main, tag pushed, GitHub release with the DMG). The recordings viewer ships labelled a proof of concept. Open: v1 checklist depth items (quit/kill -9 mid-recording, fMP4 in Slack/Telegram), "02:14" vs "2:14", `.scratch/` gitignore decision.

> **Read this first if context was cleared.** All video-recording-thread work lives in `.scratch/video-recording-thread/` —
> throwaway scripts, probes, and notes stay here, organized per thread, never in the repo or a PR.
> One-off scripts: run from the project root, e.g. `bun .scratch/video-recording-thread/probe.ts`.

## The ask (narrowed)
- **Goal (user, 2026-09-06, dictated):** Loom-style screen recording inside Kleoth. Record the **entire screen or a
  user-chosen area**, with **system audio AND mic** (macOS built-in recorder captures mic only), producing
  **small, well-compressed files** (the user currently runs ffmpeg by hand on every QuickTime capture before
  sharing). **Controls live in the dictation pill:** hover the resting pill → start recording; stop from the pill.
- Reference product: Loom (the user named it). Most important property right now: small file + system audio.
- Scope IN: capture (ScreenCaptureKit), encode (hardware H.264 + AAC, share-friendly .mp4), region picker,
  pill hover controls + a recording state in the pill, output folder + a History surface, permissions
  (Screen Recording TCC) preflight.
- Scope OUT (v1): camera bubble, editing/trimming, uploads/sharing links, transcription of recordings, per-app
  window capture, pause/resume.
- **Working assumptions (not yet confirmed by the user — redirect if wrong):** output ~/Kleoth/screen-recordings/
  <timestamp>.mp4 (not a meeting folder); H.264 (compat) at a capped resolution + ~30 fps rather than HEVC;
  mic + system mixed into one stereo AAC track; recording is independent of meeting recording and dictation
  (all three can coexist).
- **CORE PRINCIPLE — DATA-DRIVEN.** Derive values/options/categories from real data in this
  project — not from an assumption. If a spec looks like a generated example, confirm it against
  the source before building on it.

## Phase 2 — the ask (user, 2026-09-07; PoC depth, "not a full production app yet")
- Pill during recording: "ugly, small, non-responsive, not animated" → a LIVE horizontal toolbar: red dot + elapsed,
  mic + system level meters, Stop button always visible; animates in; stays horizontal on every edge (side edge = flat
  against the edge, never vertical); drag left/right must re-lay out cleanly. Pause deferred (offered, not requested).
- Recordings are NOT meetings (user: "just recordings, similar to Loom"). Own History scope "Recordings" + viewer:
  video player + transcript beside it, current word highlighted during playback, click a word → seek, edit a word in place.
- Transcription AFTER the recording is saved (user chose option 1, not live subtitles), automatic, same engine as
  meetings, word timestamps ON.
- Popover hit areas: DONE (kleothRow button style).

## Phase 2 — lanes (2026-09-07)
- T0 (me): KleothCore ScreenRecordingRecord/Store/FileNaming(sidecar,date) + 7 tests; stubs: LocalTranscriber.wordTimestamps,
  ScreenRecorder.levels (.zero), RecordingAudioExtractor (throws), DictationPillController.setRecordingLevels (no-op),
  PillCoordinator.setRecordingLevels, RecordingController.enqueuePipelineJob internal, RecordingDetailView stub.
- Lanes own disjoint files: L2 KleothCapture+screenrec/localtranscribe · L3 KleothPillUI+pillsandbox · L4 KleothApp minus
  RecordingDetailView · L5 Views/Recording*.swift. Integrate: merge worktree branches, build, swift test, films, make-app release.
- Integrated 2026-09-07: lanes merged (L5 bb277ee, L4 93cd277, L3 7e66bb4, L2 65f1dc2 → 1a559a1), worktrees removed. Docs done.
- Next: user runs the 6-item checklist; fix what fails; merge feat/recordings-viewer → main.

## Where things are
- Branch: `feat/screen-recording` (cut from main @ 06b60d0). T0 lands here; T1–T6 in worktrees; T7 merges back here. NOT pushed.
- Existing capture code: `app/Sources/KleothCapture/` — `Recorder.swift` (mic.m4a + system.m4a → meeting.m4a),
  `MicCapture.swift`, `SystemAudioTap.swift` (Core Audio process tap), `ScreenshotCapture.swift`
  (the only screen-related capture today). No video code anywhere in the repo as of 2026-09-06.
- Uncommitted at thread start (unrelated to this thread): `AudioFormat.swift`, `DictationCapture.swift`,
  `MicCapture.swift` modified; `docs/CODE-REVIEW.md` untracked.
- Meeting folder contract: `~/Kleoth/meeting-yyyy-MM-dd-HHmmss/` (see CLAUDE.md) — any video artifact
  must fit this layout and the snake_case / acronym-free stored-key rule.

## Plan (in run order)
1. Workflow phase "Understand": read pill/controller/capture code + ScreenCaptureKit/AVAssetWriter facts → design brief.
2. Workflow phase "Implement" (Opus, parallel worktrees): capture+encode library (KleothCapture), pill states +
   hover controls (KleothPillUI), controller + Settings/History wiring (KleothApp), tests in KleothCore.
3. Workflow phase "Integrate + review": merge, build both packages, run tests, adversarial review, fix.
4. Human verification: real screen recording with system audio, file size check, pill controls by eye.

## Current state (as of 2026-09-06)
- Workflow 1 DONE (run wf_4f3c81a0-a63, resumed once after an ENOTFOUND outage). Outputs in this dir:
  design-A-minimal.md, design-B-robust.md (B won 8/7.5 with A grafts), DESIGN.md (final, 9 sections), TASKS.md (T0–T7),
  research-macos-capture-apis.md. Key decisions: SCStream .screen+.audio + third AVAudioEngine mic → 20 ms pull mixer →
  ONE AAC track; AVAssetWriter H.264 ≤1920 long edge, 30 fps, 3 Mbps area-scaled (floor 1 Mbps); fMP4 10 s fragments
  (compat to verify §8 #16); @MainActor ScreenRecorder; pill .recording(since:)/.saving/.saved + backdrop concept via
  PillCoordinator; whole-app SCK exclusion; no Settings/Keychain key; files ~/Kleoth/screen-recordings/screen-<ts>.mp4.
- ⚠️ Blocking risk: Screen Recording TCC on the no-Team-ID "Kleoth Self-Signed" identity (§8 #0) — human step in T7.
- The thread STATE.md got committed+pushed in 72cca9a by another session (.scratch not ignored). User to decide.
- Workflow 2 (implement) DONE (run wf_e820bb30-1c3, 7 Opus agents, ~94 min): T0 = 5f6e6d5 on feat/screen-recording; lanes on
  branches worktree-wf_e820bb30-1c3-{2=T1,3=T2,4=T3,5=T4,6=T5,7=T6} (worktrees under .claude/worktrees/ — delete after merge
  is confirmed). Merged in order T1→T3→T2→T4→T5→T6 (all clean, HEAD b4f9071). Lane reports summarized into docs by workflow 3.
  Notable lane deviations: T1 fixed CaptureGeometry's 2 px cap dent + machine accepts startRequested from .saved/.failed and
  stopRequested from picker/permission (→ idle); T3 added sessionOriginHostTime, partial tail audio block, events finish on
  every exit, ~30 ms mic-trails-system measured, 22.2 MB/min over 300 s; T5 defers the terminate reply one turn, polls the
  queued .saved (auto-hide bypasses onDismiss), faultOverride for finalizeTimedOut; T6 headerSubtitleView with TimelineView;
  "02:14" padded minutes everywhere (design prose said "2:14").
- Integration checks on the merged branch (inline): swift test 334/334; app build green (pre-existing warnings only);
  screenrec 10 → films/T7/t7-10s.mp4 10.05 s, 296 frames, 500 audio blocks, H.264 3.07 Mbps + AAC 48k stereo, 22.6 MB/min;
  pillsandbox film films/T7/bottom/sheet.png — recording/armed/listening/done→recording/peek(stop glyph)/saving/saved/idle read right.
- Workflow 3: run wf_b49036bb-402 died twice on the usage limit; lean rerun wf_83f84386-5be (3 lenses) died once on ENOTFOUND, resumed,
  DONE (10 agents). 5 medium findings CONFIRMED + fixed by the Opus fixer (withDeadline for non-cancellable finalize/shareable-content;
  renameWhenFinishLands; showSaved ordering; dismissRecordingPhase on retry; RegionPicker focus restore) → 338 tests. 4 lows left
  unverified (listed in CLAUDE.md status). Docs agent wrote the CLAUDE.md section + status block, CHANGELOG, docs/plans/2026-09-06-screen-recording.md.
- Hand fixes (orchestrator): pill dismissingState (Reduce-Motion misroute), controller startFailure (real cause on stop-during-start),
  ScreenRecordingDefaults header repointed to docs/plans. Verified: 338 tests, app builds, screenrec 5 OK, regression film idle→listening→done→idle OK.
  Release app built + installed via make-app.sh release (running instance NOT killed).
- User confirmed item 0 PASSED ("that's work") — feature unblocked. Remaining checklist items 1–8 are optional depth checks.
- Next (user's call): merge feat/screen-recording → main + push; "02:14" vs "2:14"; .scratch gitignore.
  Still the user's call: merge to main / push, "02:14" vs "2:14", .scratch gitignore (STATE.md is tracked+pushed since 72cca9a).

## Open / deferred (don't start without the user)
- Whether `.scratch/` should be gitignored (not ignored at thread start; repo is PUBLIC on GitHub).
