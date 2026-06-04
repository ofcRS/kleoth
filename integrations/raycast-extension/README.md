# Kleoth Raycast Extension

A proper Raycast extension (not script commands) for the Kleoth meeting recorder.

## Commands

| Command | What it does |
| --- | --- |
| **Toggle Recording** | Start if idle, stop & transcribe if recording (`kleoth://toggle`) |
| **Start Recording** | Begin recording mic + system audio |
| **Stop & Transcribe** | Stop and transcribe on-device |
| **Search Meetings** | Browse all meetings: open/copy summary & transcript, copy file paths, reveal in Finder |
| **Latest Summary** | Read the newest meeting's summary as rendered markdown |

## Install (local, no store needed)

```bash
cd integrations/raycast-extension
npm install
npm run dev        # registers the extension in Raycast (Development section), Ctrl-C after it opens
```

The extension persists in Raycast after you stop the dev watcher. Re-run `npm run dev`
after editing the source.

## Notes

- Recording commands drive the running app via the `kleoth://` URL scheme — install
  `/Applications/Kleoth.app` first.
- Browsing reads `~/Kleoth` directly (plain files); override via the extension's
  "Meetings Folder" preference.
- The older script-command set in `../raycast/` still works and stays for users who
  prefer plain shell scripts.
