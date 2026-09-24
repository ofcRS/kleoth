# Kleoth's public positioning

Kleoth's pitch used to be copied by hand into about seven places, and they drifted: "meeting
recorder" long after dictation and screen recording shipped. Now the short public copy lives in
one file, and a script writes it everywhere else.

| File | What it is |
|---|---|
| `positioning.json` | **The source.** Tagline, GitHub About/topics/homepage, the three jobs and their status, the BYO-AI line, short descriptions, image text, `reviewed_for`. |
| `sync.ts` | `check` reports drift, `apply` writes everything below, `hook` is the release gate. |
| `positioning.lock.json` | Written by `apply`: a fingerprint of the image text, so `check` knows when the images are stale. |
| `sync.test.ts` | `bun test ./marketing/sync.test.ts`: the hook's command parser (what counts as tagging or publishing a release). |

What `apply` writes from it:

- `README.md`: the block between `<!-- positioning:start -->` and `<!-- positioning:end -->`, and
  the download link between `<!-- release:start -->` and `<!-- release:end -->` (version, size and
  SHA-256 from `app/bundle/Info.plist` and `app/dist/`)
- `docs/assets/hero.png` and `docs/assets/social-preview.png`, via
  `app/branding-src/readme-images/generate.swift`
- `packaging/homebrew/kleoth.rb`: `desc`, and `version` + `sha256` from `app/dist/`
- `integrations/raycast-extension/package.json`: `description`
- `app/make-dmg.sh`: the DMG's *Read Me.txt* heading
- GitHub: the repo's About text, homepage and topics (`gh repo edit` and the topics API; skip with
  `--no-remote`)

The long-form pages, `docs/dictation.md`, `docs/meetings.md`, `docs/screen-recording.md` and
`docs/ai-providers.md`, are hand-written. `check` can't see into them, so the release review below
covers them.

```sh
bun marketing/sync.ts check              # what's stale (exit 1 if anything)
bun marketing/sync.ts check --offline    # without the live GitHub About/topics
bun marketing/sync.ts apply              # write it all, including GitHub
bun marketing/sync.ts apply --no-remote  # files only
```

## Every release

The release gate is `reviewed_for`. The copy can't be generated from a changelog, so the gate
makes a person (or Claude) review it. `check` fails while `reviewed_for` is not the version in
`Info.plist`. The Claude Code hook in `.claude/settings.json` runs that check before any
`git tag vX.Y.Z` or `gh release create` (also through `git -C`, `gh -R`, `env`, subshells) and
blocks it until it passes. It also requires everything `apply` writes to be committed, and it
blocks when the check itself errors. `docs/RELEASING.md` has the
same step for releases cut by hand, and the `announce-release` workflow warns if the live
About/topics don't match after a release.

1. Read the new `CHANGELOG.md` section against `positioning.json` and the four `docs/*.md` pages:
   - A new job or a big new capability? Add it to `jobs`, the About text and the topics, and give
     it a page.
   - Something left beta? Change its `status`, and drop "beta" from its page and the README section.
   - A limit gone (see **Claims held back** below)? Make the claim.
   - A limit added, or a claim no longer true? Take it out.
   - Features described as "from the next release" that this release ships? Drop the qualifier.
2. Set `reviewed_for` to the new version.
3. After `bash app/make-dmg.sh`, run `bun marketing/sync.ts apply`. That writes the copy, the
   download link, the cask version and SHA, the images if their text changed, and the GitHub
   About/topics.
4. If the pill changed this release, re-render the pill demos: `bash app/branding-src/demo/make-demos.sh`
   (the real pill on a drawn stage; nothing is captured from the screen). If History, the meeting
   view or the recordings viewer changed, re-render those and the screenshot:
   `bash app/branding-src/demo/make-app-demos.sh` (~5 min; the fictional meetings are summarized
   through your Claude Code; a demo copy of the app films its own window from behind yours).
5. If `social-preview.png` changed, upload it by hand: GitHub → Settings → General → Social
   preview. GitHub has no API for it; `check` and `apply` remind you.
6. Commit, then tag and release.
7. After a copy change, run the [discovery queries](#discovery-queries).

## Claims held back

Claims Kleoth could make for discovery, held until they're true:

- **"Wispr Flow / Superwhisper alternative"** and the topic `wispr-flow-alternative`: wait until
  live dictation can run on device. Today its speech-to-text is ElevenLabs Scribe, so the copy says
  "Wispr Flow-style" and names Scribe next to it (decided 2026-09-24).
- **"Loom alternative"** and the topic `loom-alternative`: wait until trimming, sharing and export
  exist. Until then it's "Loom-style (beta)".
- **"Notarized"**, `brew install --cask kleoth`, auto-update: wait until the Developer ID build
  ships (`docs/RELEASING.md` §6).

## Discovery queries

A fixed set to re-run in ChatGPT, Claude, Perplexity and Google after a copy change and after each
release. Note whether Kleoth appears, and how it's described. Meetings is the cluster that already
finds Kleoth (2026-09). The others are the goal.

- **Meetings:** "open source bot-free meeting recorder Mac" · "private Otter alternative macOS" ·
  "local Granola alternative" · "record Zoom locally on Mac without a bot"
- **Dictation:** "open source Wispr Flow alternative" · "Superwhisper alternative Mac" ·
  "local-first Mac voice typing"
- **Bring your own AI:** "Claude Code meeting recorder" · "Codex meeting summarizer" ·
  "dictation OpenRouter macOS" · "Mac meeting recorder with Ollama"
- **Screen:** "local-first Loom alternative Mac" · "open-source screen recorder with transcript"

## Later: a Kleoth landing page on shck.dev

Planned, not built (noted 2026-09-24): a page at **shck.dev/kleoth** on the Astro site in
`~/projects/shck.dev`. That site already receives a `tool-release` dispatch from
`.github/workflows/announce-release.yml`, rebuilds `/changelog` and drafts a release post. When
the page is built:

- Feed it from `positioning.json` (fetched at build time, or sent in the dispatch payload) so it
  can't drift from the README.
- Set `github.homepage` here to its URL, and `apply`.
- shck.dev still calls Kleoth a meeting recorder in three hand-written places: the `kleoth` blurb
  in `src/site.config.ts` `TOOLS`, `SITE.description`, and the hero sentence in
  `src/pages/index.astro`.
