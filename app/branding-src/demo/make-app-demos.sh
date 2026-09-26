#!/usr/bin/env bash
# README demos from the app's OWN windows over demo data (design: docs/plans/2026-09-24-demo-mode.md).
#
#   bash app/branding-src/demo/make-app-demos.sh [data-dir]
#     → docs/assets/demo-meeting.gif, demo-viewer.gif, screenshot-detail.png
#   KLEOTH_DEMO_FRAMES=<dir> bash app/branding-src/demo/make-app-demos.sh <data-dir>
#     → <dir>/frame-000N.png: the meeting page with a cover (verification, no GIF; nothing under docs/)
#
# data-dir is what make-demo-data.ts wrote (a stand-in for ~/Kleoth, marked .kleoth-demo) — or a hand-made
# folder of fictional copies carrying the same marker, like the covers-hero fixtures; without
# one it runs make-demo-data.ts into a temp folder first. Nothing of yours is read or written:
# the films come from a temporary copy of the app, KleothDemo.app, with its own bundle id
# (dev.kleoth.demo: its own defaults, saved state and privacy grants — none) started with
# -KleothDemo, which gates the Keychain, the hotkeys, the pill, the launch sweeps and the
# menu-bar item in code. Its History window films itself from BEHIND your windows, is launched
# in the background (open -g) and never takes focus; its playback is muted. Each film runs
# ~20 s. Needs ffmpeg and bun.
set -euo pipefail

# Frames mode is chosen by KLEOTH_DEMO_FRAMES being SET. Set but empty is a mistake (an unset
# variable in a caller's script, say): refuse it before anything is built, never fall through
# to README mode, which overwrites the tracked GIFs and screenshot under docs/assets.
if [ -n "${KLEOTH_DEMO_FRAMES+x}" ] && [ -z "${KLEOTH_DEMO_FRAMES}" ]; then
  echo "KLEOTH_DEMO_FRAMES is set but empty: give it the folder for the frames (or unset it for the README demos)" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
command -v ffmpeg >/dev/null || { echo "ffmpeg not found (brew install ffmpeg)" >&2; exit 1; }

WORK="$(mktemp -d)"
APP="$WORK/KleothDemo.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
cleanup() {
  pkill -f "$APP/Contents/MacOS/" 2>/dev/null || true
  [ -d "$APP" ] && "$LSREGISTER" -u "$APP" 2>/dev/null || true
  defaults delete dev.kleoth.demo >/dev/null 2>&1 || true
  tccutil reset All dev.kleoth.demo >/dev/null 2>&1 || true
  rm -rf "$HOME/Library/Saved Application State/dev.kleoth.demo.savedState" \
         "$(getconf DARWIN_USER_CACHE_DIR)dev.kleoth.demo" "$HOME/Library/Caches/dev.kleoth.demo"
  rm -rf "$WORK"
}
trap cleanup EXIT

DATA="${1:-}"
if [ -z "$DATA" ]; then
  DATA="$WORK/data"
  bun app/branding-src/demo/make-demo-data.ts "$DATA"
fi
DATA="$(cd "$DATA" && pwd)"
# Only a folder make-demo-data.ts made (or hand-made fictional fixtures, like the covers-hero ones, marked
# the same way): never ~/Kleoth, whose meetings would land in the README.
[ -f "$DATA/.kleoth-demo" ] || { echo "$DATA was not made by make-demo-data.ts (no .kleoth-demo)" >&2; exit 1; }

# --- KleothDemo.app: the app under another identity, with nothing it could ask for ---
swift build --package-path app --product KleothApp
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp app/bundle/Info.plist "$APP/Contents/Info.plist"
PLIST="$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string dev.kleoth.demo "$PLIST"
plutil -replace CFBundleName -string "Kleoth Demo" "$PLIST"
plutil -replace CFBundleDisplayName -string "Kleoth Demo" "$PLIST"
# No kleoth:// routing, and no usage strings: a missed gate that reached for the mic,
# system audio or the calendar would crash the copy, not prompt you.
for key in CFBundleURLTypes NSMicrophoneUsageDescription NSAudioCaptureUsageDescription \
           NSCalendarsUsageDescription NSCalendarsFullAccessUsageDescription; do
  plutil -remove "$key" "$PLIST"
done
cp app/.build/debug/KleothApp "$APP/Contents/MacOS/Kleoth"
cp -R app/.build/debug/KleothApp_KleothApp.bundle "$APP/Contents/Resources/"
[ -f app/bundle/Kleoth.icns ] && cp app/bundle/Kleoth.icns "$APP/Contents/Resources/"
# Ad hoc, no entitlements: not the "Kleoth Self-Signed" identity your Keychain item trusts.
codesign --force --sign - "$APP" >/dev/null

film() { # <script> <out dir>
  mkdir -p "$2"
  open -g -n -W --stdout "$2/director.log" --stderr "$2/director.log" "$APP" --args \
    -KleothDemo "$DATA" -KleothDemoFilm "$2" -KleothDemoScript "$1"
  cat "$2/director.log"
  [ -f "$2/frames.txt" ] || [ "$1" = still ] || { echo "no film for $1" >&2; exit 1; }
}

encode() { # <film dir> <out.gif>
  ffmpeg -loglevel error -y -f concat -safe 0 -i "$1/frames.txt" \
    -vf "fps=15,split[a][b];[a]palettegen=max_colors=192:stats_mode=full[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" \
    "$2"
}

# Verification frames only (plan 2026-09-25): KLEOTH_DEMO_FRAMES=<dir> films the
# `cover` script into <dir> as PNGs and stops — nothing under docs/ is touched.
# (It still needs ffmpeg: the check above runs first.)
if [ -n "${KLEOTH_DEMO_FRAMES+x}" ]; then
  mkdir -p "$KLEOTH_DEMO_FRAMES"
  # Absolute, as -KleothDemoFilm requires (a relative one is from the repo root, like data-dir).
  FRAMES="$(cd "$KLEOTH_DEMO_FRAMES" && pwd)"
  # Only the director's own files from an earlier run: a stale frames.txt would hide a failed film.
  rm -f "$FRAMES"/frame-*.png "$FRAMES/frames.txt" "$FRAMES/director.log"
  film cover "$FRAMES"
  ls -1 "$FRAMES"/frame-*.png
  exit 0
fi

film meeting "$WORK/meeting"
film viewer "$WORK/viewer"
film still "$WORK/still"

[ -f "$WORK/still/frame-0000.png" ] || { echo "no still" >&2; exit 1; }
# All three are made before any tracked file changes.
encode "$WORK/meeting" "$WORK/demo-meeting.gif"
encode "$WORK/viewer" "$WORK/demo-viewer.gif"
cp "$WORK/demo-meeting.gif" "$WORK/demo-viewer.gif" docs/assets/
cp "$WORK/still/frame-0000.png" docs/assets/screenshot-detail.png
ls -lh docs/assets/demo-meeting.gif docs/assets/demo-viewer.gif docs/assets/screenshot-detail.png
