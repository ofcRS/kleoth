---
title: video-recording-thread
kind: thread
summary: 'Video recording for Kleoth — goal not yet agreed (TODO); thread opened 2026-09-06, nothing built.'
---

# video-recording-thread — video recording for Kleoth · handoff state

**Hub:** [[INDEX]]
**Status:** opened 2026-09-06 — scope not yet agreed; no code, no probes. Waiting on a one-line goal from the user.

> **Read this first if context was cleared.** All video-recording-thread work lives in `.scratch/video-recording-thread/` —
> throwaway scripts, probes, and notes stay here, organized per thread, never in the repo or a PR.
> One-off scripts: run from the project root, e.g. `bun .scratch/video-recording-thread/probe.ts`.

## The ask (narrowed)
- TODO: one-line goal from the user. Working guess (UNCONFIRMED): add video/screen recording alongside the
  existing mic + system-audio meeting capture.
- Scope right now = _(TODO: fill when scope is agreed — what's in / explicitly out)_.
- **CORE PRINCIPLE — DATA-DRIVEN.** Derive values/options/categories from real data in this
  project — not from an assumption. If a spec looks like a generated example, confirm it against
  the source before building on it.

## Where things are
- Branch: `main` (no feature branch or worktree yet).
- Existing capture code: `app/Sources/KleothCapture/` — `Recorder.swift` (mic.m4a + system.m4a → meeting.m4a),
  `MicCapture.swift`, `SystemAudioTap.swift` (Core Audio process tap), `ScreenshotCapture.swift`
  (the only screen-related capture today). No video code anywhere in the repo as of 2026-09-06.
- Uncommitted at thread start (unrelated to this thread): `AudioFormat.swift`, `DictationCapture.swift`,
  `MicCapture.swift` modified; `docs/CODE-REVIEW.md` untracked.
- Meeting folder contract: `~/Kleoth/meeting-yyyy-MM-dd-HHmmss/` (see CLAUDE.md) — any video artifact
  must fit this layout and the snake_case / acronym-free stored-key rule.

## Plan (in run order)
1. Agree the one-line goal + in/out scope with the user → fill "The ask".
2. TODO: brainstorm/design once scope is known (capture API choice, file format, UI surface, permissions).

## Current state (as of 2026-09-06)
- Thread scaffolded only. Nothing designed, built, or verified.

## Open / deferred (don't start without the user)
- The goal itself (see The ask).
- Whether `.scratch/` should be gitignored (not ignored at thread start; repo is PUBLIC on GitHub).
