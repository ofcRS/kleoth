#!/usr/bin/env bash
# README demos, rendered from the REAL pill (pillsandbox --film --demo) and encoded to GIF.
#
#   bash app/branding-src/demo/make-demos.sh   → docs/assets/demo-dictation.gif, demo-screen.gif
#
# No microphone, no screen capture, no Accessibility: the pill is the app's own
# DictationPillController driven through its phases, captured from its own window;
# the desktop, the editor/slide window, the captions, the keys and the cursor are
# drawn around it with sample content (app/Sources/pillsandbox/Demo.swift). The
# pill appears at the bottom of the screen for ~10 s per film; it takes no focus.
# Needs ffmpeg.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
command -v ffmpeg >/dev/null || { echo "ffmpeg not found (brew install ffmpeg)" >&2; exit 1; }

swift build --package-path app --product pillsandbox
BIN="app/.build/debug/pillsandbox"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Dictation: hold fn+shift (armed → listening), let go, transcribe, polish, paste.
"$BIN" --film "$WORK/dictation" --demo dictation --edge bottom --backdrop idle \
  --sequence "idle@1.4,armed@0.3,listening@3.6,transcribing@1.0,polishing@0.9,done@1.4,idle@1.8"

# Screen: hover the pill, click Record, record with live meters, click Stop, saved.
"$BIN" --film "$WORK/screen" --demo screen --edge bottom --backdrop idle --levels speech \
  --sequence "idle@1.2,peek@0.9,hover:rec@0.8,click:rec@0.3,unpeek@4.2,peek@0.3,hover:stop@0.9,click:stop@0.3,unpeek@3.0"

encode() { # <film dir> <out.gif>
  ffmpeg -loglevel error -y -f concat -safe 0 -i "$1/demo/frames.txt" \
    -vf "fps=20,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=192:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
    "$2"
}
encode "$WORK/dictation" docs/assets/demo-dictation.gif
encode "$WORK/screen" docs/assets/demo-screen.gif
ls -lh docs/assets/demo-*.gif
