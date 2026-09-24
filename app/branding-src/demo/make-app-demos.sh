#!/usr/bin/env bash
# README demos from the app's OWN windows over demo data (design: docs/plans/2026-09-24-demo-mode.md).
#
#   bash app/branding-src/demo/make-app-demos.sh [data-dir]
#     → docs/assets/demo-meeting.gif, demo-viewer.gif, screenshot-detail.png
#
# data-dir is what make-demo-data.sh wrote (a stand-in for ~/Kleoth); without one it
# runs make-demo-data.sh into a temp folder first. Nothing of yours is read or written:
# the films come from a temporary copy of the app, KleothDemo.app, with its own bundle id
# (dev.kleoth.demo: its own defaults, saved state and privacy grants — none) started with
# -KleothDemo, which gates the Keychain, the hotkeys, the pill, the launch sweeps and the
# menu-bar item in code. Its History window films itself from BEHIND your windows and never
# takes focus; each film runs ~20 s. Needs ffmpeg.
set -euo pipefail

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
  rm -rf "$HOME/Library/Saved Application State/dev.kleoth.demo.savedState"
  rm -rf "$WORK"
}
trap cleanup EXIT

DATA="${1:-}"
if [ -z "$DATA" ]; then
  DATA="$WORK/data"
  bash app/branding-src/demo/make-demo-data.sh "$DATA"
fi
DATA="$(cd "$DATA" && pwd)"

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
  open -n -W --stdout "$2/director.log" --stderr "$2/director.log" "$APP" --args \
    -KleothDemo "$DATA" -KleothDemoFilm "$2" -KleothDemoScript "$1"
  cat "$2/director.log"
  [ -f "$2/frames.txt" ] || [ "$1" = still ] || { echo "no film for $1" >&2; exit 1; }
}

encode() { # <film dir> <out.gif>
  ffmpeg -loglevel error -y -f concat -safe 0 -i "$1/frames.txt" \
    -vf "fps=15,split[a][b];[a]palettegen=max_colors=192:stats_mode=full[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" \
    "$2"
}

film meeting "$WORK/meeting"
film viewer "$WORK/viewer"
film still "$WORK/still"

encode "$WORK/meeting" docs/assets/demo-meeting.gif
encode "$WORK/viewer" docs/assets/demo-viewer.gif
cp "$WORK/still/frame-0000.png" docs/assets/screenshot-detail.png
ls -lh docs/assets/demo-meeting.gif docs/assets/demo-viewer.gif docs/assets/screenshot-detail.png
