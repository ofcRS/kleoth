# Positioning: one pitch for three jobs, kept current by the release (design, 2026-09-24)

Kleoth's public metadata still described it as "a local-first, bot-free macOS meeting recorder"
after dictation (0.2.0), screen recording (0.3.0) and bring-your-own-AI (0.4.0) shipped. Search
engines and LLMs found it for bot-free meeting queries and not for dictation, AI-provider or
screen-recording ones. A competitive review the user pasted on 2026-09-24 recommended
repositioning it as a local-first voice and capture app with three jobs, **Dictate · Meet ·
Record screen**, and rewriting the About text, topics, README top and social preview around them.
The user asked for that, plus a per-release hook that keeps all of this commercial copy current.

## 1. Decisions (user, 2026-09-24)

- **Dictation wording: "Wispr Flow-style", not "alternative".** Live dictation's speech-to-text
  is ElevenLabs Scribe in the cloud; only the retry of a failed dictation runs on device. The
  copy names Scribe next to the claim. "Wispr Flow / Superwhisper alternative" and the topic
  `wispr-flow-alternative` are held until live dictation can run on device.
- **Screen recording is "Loom-style (beta)".** "Loom alternative" and the topic
  `loom-alternative` are held until trimming, sharing and export exist.
- **Meetings may claim "alternative"**: "a local, open-source alternative to Granola, and a
  bot-free one to Otter, Fireflies and tl;dv". Granola is bot-free but hosted; the others are
  built around a notetaker that joins the call.
- **Mechanism: source file + sync script + Claude Code hook** (over a GitHub Action with an
  admin PAT, or a checklist alone).
- **Ship by PR; GitHub About/topics are applied after the merge**, so the live metadata never
  runs ahead of the README on `main`.
- **Landing page later at shck.dev/kleoth**, fed from the same file (`marketing/README.md`).
- **Privacy copy names the Automatic default.** Summaries run after every transcription on whatever
  provider resolves, and Automatic picks a signed-in Claude Code or Codex CLI when no local server
  runs. So "nothing leaves your Mac" is claimed only for recording and on-device transcription, and
  every page says where transcripts go. Found in review: the old README already overstated this.
  An "Off" provider choice would make the story simpler; that is an open product question.
- Short, heavily indexed strings (About, cask, Raycast, image sub-line) never put "on-device" or
  "local-first" in front of dictation.
- Features still in `[Unreleased]` (dictation Retry, complete-only summaries) are described as
  arriving "from the next release"; the release review drops the qualifier.
- Left alone on purpose: the popover subtitle "Local-first meeting recorder" in `MenuView`,
  whose comment records meetings as the app's primary job (§2.3 of the pill design). That is a
  product decision, not copy drift.

## 2. Contract

- `marketing/positioning.json` is the only place the short pitch is written: `tagline`,
  `github.{repo, about, homepage, topics}`, `intro`, `jobs[]` (`id`, `title`, `status`, `page`,
  `line`), `byo_ai`, `byo_ai_page`, `closer`, `short.{homebrew, raycast, dmg}`,
  `image.{jobs, tagline, sub}`, `reviewed_for`.
- `bun marketing/sync.ts apply [--no-remote]` writes:
  - the README blocks between `<!-- positioning:start/end -->` and `<!-- release:start/end -->`
  - the cask `desc`, `version` and `sha256`
  - the Raycast `description`
  - the DMG *Read Me.txt* heading in `app/make-dmg.sh`
  - `hero.png` and `social-preview.png` (`generate.swift` reads the JSON), only when
    `positioning.lock.json`'s fingerprint of the image text + script changed
  - the GitHub About, homepage (`gh repo edit`) and topics (`PUT /repos/{repo}/topics`)

  Version facts (DMG size and SHA-256) come from `app/dist/Kleoth-<v>.dmg(.sha256)`, with `<v>`
  taken from `Info.plist`. A missing DMG skips those targets.
- `check [--offline] [--release] [--version X]` exits 1 on any drift. It also fails when
  `reviewed_for` ≠ the version, when `Info.plist` ≠ `--version`, and (with `--release`) when
  there is no DMG. Without a DMG, it checks only that the README and cask name the version. It
  reminds you to upload the social preview when that changed since the last tag. GitHub has no
  API for that upload.
- `hook` reads Claude Code's PreToolUse JSON from stdin. `releaseCommand()` finds a shell segment
  that runs `git tag … vX.Y.Z` or `gh release create`: through `git -C/-c`, `gh -R/--repo`, `env`,
  `command`, VAR=value and subshells, and ignoring quoted text for flags and the version. List,
  delete, verify and query forms are skipped. For a release, the hook requires everything `apply`
  writes plus `marketing/` and the four pages to be committed, then runs `check --release` for that
  version (falling back to `Info.plist`). It exits 2 on any failure or error, since exit 1 would
  not block. Everything else exits 0 without reading `positioning.json`. Tests:
  `bun test ./marketing/sync.test.ts`.
- `.claude/settings.json`: `PreToolUse` / `Bash` → `bun marketing/sync.ts hook`. It is guarded
  by `command -v bun` and the script being present, so a machine without bun is never blocked.
- `.github/workflows/announce-release.yml` job `positioning`: `check --version <tag>` on
  release, and a `::warning::` on drift. The job never fails.
- `docs/RELEASING.md` step 9 is the same review for releases cut by hand.

## 3. Content

- **README:** the generated hero (image, badges, tagline, intro, the three jobs with their pages,
  BYO AI, closer), then a slot comment for three demo GIFs. Then one section per job, with the
  search phrase in its heading, "Bring your own AI" moved up from the middle, and the star
  call-to-action.
- **Accuracy fixes** found along the way:
  - Quick start said a stopped meeting transcribes automatically. That has been opt-in since 0.2.0.
  - "Kleoth never uploads audio unless you trigger cloud transcription" ignored dictation.
  - Requirements and Configuration said only OpenRouter could power summaries or clean-up.
- **`docs/dictation.md`, `docs/meetings.md`, `docs/screen-recording.md`, `docs/ai-providers.md`:**
  landing-style pages. Each opens with a one-paragraph answer, then how it works, files on disk,
  what leaves the Mac, setup, honest limits and links. They are hand-written, and the release
  review covers them.
- **Topics (20):** macos, local-first, open-source, dictation, voice-typing, voice-to-text,
  meeting-recorder, meeting-notes, screen-recording, speech-to-text, transcription, privacy,
  on-device, whisperkit, elevenlabs, openrouter, claude-code, codex, ollama, granola-alternative.
  Dropped: swift, swiftui, menu-bar-app, whisper.

## 4. Verification (2026-09-24)

- `check --offline` passes after `apply --no-remote`. A hand-broken cask `desc` fails `check`, and
  `apply` repairs it.
- Hook pipe tests:
  - `ls`, `git tag -l` and `git tag -d v0.4.0` → exit 0
  - `git status && git tag v0.5.0` → exit 2, listing Info.plist, `reviewed_for`, DMG, README,
    cask and GitHub drift
  - `gh release create v0.4.0 …` → exit 2 on the live About/topics until `apply`
- Live in-session: `git tag v0.4.0` was blocked by the hook.
- After the review, in a throwaway worktree: a broken README marker, `gh` missing from PATH and a
  malformed `positioning.json` all block with exit 2, and an uncommitted cask blocks. A
  non-release command with a malformed `positioning.json` still exits 0. The parser passes 33
  cases (18 blocked shapes, 15 let through).
- An independent review checked every concrete claim in the copy against the code. Fixed after it:
  the Automatic-provider privacy claims, dictation paired with "on-device", the one-time consent
  notice, Whisper large-v3 **turbo**, the 1920 px long edge, the pill that only shows while dictation
  is on, the Claude Code token and cost claims, the softened competitor wording, and the
  unreleased-feature qualifiers.
- Images re-rendered and checked by eye.
- No package sources changed. `swift build` and `swift build --package-path app` succeed.
  `swift test` (490 tests) passed four runs in a row. One earlier cold run (7.3 s against 4.2 s)
  reported 3 issues that never came back; the output was not kept, so the flaky test is
  unidentified.

## 5. Left for the user

- After merge: `bun marketing/sync.ts apply`, which pushes the About, homepage and topics. Then
  upload `docs/assets/social-preview.png`.
- Record the three demo GIFs (slot comment at the top of the README).
- Re-run the discovery queries in `marketing/README.md` a week or two after the copy lands.
