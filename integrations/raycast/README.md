# Kleoth × Raycast

Raycast [Script Commands](https://manual.raycast.com/script-commands) that drive Kleoth. Most are thin wrappers around Kleoth's `kleoth://` URL scheme, so they reuse the running app's Keychain keys and live recording session — no separate setup.

## Commands

| Command | What it does | How |
| --- | --- | --- |
| Kleoth: Start Recording | Begin a recording | `open kleoth://record` |
| Kleoth: Stop & Transcribe | Stop + transcribe | `open kleoth://stop` |
| Kleoth: Summarize Latest | Summarize the newest meeting (app's model) | `open kleoth://summarize-latest` |
| Kleoth: Open Latest Transcript | Open `transcript.md` of the newest meeting | filesystem |
| Kleoth: Save Latest to Obsidian | Copy newest summary/transcript into a vault | filesystem (vault path arg) |

## Setup

1. Install the app so the URL scheme is registered: `bash app/setup-signing.sh` then `bash app/make-app.sh release` (installs `/Applications/Kleoth.app`).
2. In Raycast: **Extensions → Script Commands → Add Script Directory**, and pick this `integrations/raycast/` folder.
3. The commands appear in Raycast as “Kleoth: …”. Bind hotkeys/aliases as you like.

## Notes

- The URL-based commands need the app installed (for the `kleoth://` scheme) and, for record/stop, the usual mic + system-audio TCC grants.
- `Open Latest Transcript` and `Save Latest to Obsidian` read `~/Kleoth` directly; override with `KLEOTH_DIR=/path` if your output folder differs.
- **App Intents alternative:** Kleoth also exposes Start / Stop / Summarize Latest / Get Latest Transcript as **Shortcuts** actions (and Spotlight on macOS 26). Raycast can run those Shortcuts too — use whichever you prefer.
- Prefer the free `summarize-meeting` Claude Code skill if you don't want to spend on the summarization API; “Summarize Latest” here uses the app's configured (paid) model.
