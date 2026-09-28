#!/usr/bin/env bash
# The packaged-app smoke test: does the app that SHIPS open its screens on a Mac that did not build it?
#
# Usage:  bash app/smoke-test.sh [path/to/Kleoth.app]     (default: app/dist/Kleoth.app)
#         KLEOTH_SMOKE_FRAMES=<dir> bash app/smoke-test.sh  also keeps one PNG per screen in <dir>
#
# SwiftPM's `Bundle.module` falls back to the build Mac's `.build` folder, so an app that crashes on
# every other Mac (#17 at launch, #22 in Settings) runs fine where it was built. This test moves every
# build folder the binary names out of the way first (and back afterwards, whatever happens), then
# runs a copy of the app through the demo launch's `smoke` script (DemoDirector.smokeScript): History
# with the fixture meeting open, its other two scopes, and all six Settings pages. It fails on a
# crash, a failed check, or a hang, and prints why.
#
# Nothing of yours is read or written. The copy is KleothDemo.app (docs/plans/2026-09-24-demo-mode.md):
# its own bundle id (dev.kleoth.demo: its own defaults, saved state and privacy grants, none of them
# yours), no usage strings, ad hoc signed, over a copy of app/smoke/fixture. `-KleothDemo` gates the
# Keychain, the hotkeys, the pill, the launch sweeps and the menu-bar item in code. Its windows sit
# behind yours and never take focus. About 20 s. A failure shows macOS's crash dialog: that is the
# crash the test caught.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"     # the app/ package directory
SRC="${1:-$DIR/dist/Kleoth.app}"
[ -x "$SRC/Contents/MacOS/Kleoth" ] || { echo "smoke: no app at $SRC (run make-app.sh release first)" >&2; exit 1; }
SRC="$(cd "$SRC" && pwd)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kleoth-smoke.XXXXXX")"
APP="$WORK/KleothDemo.app"
LOG="$WORK/director.log"
FILM="$WORK/frames"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
HIDDEN=()   # build folders moved aside, restored by cleanup
PID=""

forget_demo_identity() {
  defaults delete dev.kleoth.demo >/dev/null 2>&1 || true
  tccutil reset All dev.kleoth.demo >/dev/null 2>&1 || true
  rm -rf "$HOME/Library/Saved Application State/dev.kleoth.demo.savedState" \
         "$(getconf DARWIN_USER_CACHE_DIR)dev.kleoth.demo" "$HOME/Library/Caches/dev.kleoth.demo"
}

cleanup() {
  [ -n "$PID" ] && kill -9 "$PID" 2>/dev/null || true
  for ROOT in "${HIDDEN[@]+"${HIDDEN[@]}"}"; do
    mv "$ROOT.smoke-aside" "$ROOT" && echo "smoke: restored $ROOT"
  done
  [ -d "$APP" ] && "$LSREGISTER" -u "$APP" 2>/dev/null || true
  forget_demo_identity
  if [ -n "${KLEOTH_SMOKE_FRAMES:-}" ] && [ -d "$FILM" ]; then
    mkdir -p "$KLEOTH_SMOKE_FRAMES"
    cp "$FILM"/frame-*.png "$KLEOTH_SMOKE_FRAMES"/ 2>/dev/null || true
    echo "smoke: frames in $KLEOTH_SMOKE_FRAMES"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- KleothDemo.app: the app as shipped, under another identity, with nothing it could ask for ---
cp -R "$SRC" "$APP"
PLIST="$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string dev.kleoth.demo "$PLIST"
plutil -replace CFBundleName -string "Kleoth Demo" "$PLIST"
for key in CFBundleURLTypes NSMicrophoneUsageDescription NSAudioCaptureUsageDescription \
           NSCalendarsUsageDescription NSCalendarsFullAccessUsageDescription; do
  plutil -remove "$key" "$PLIST" 2>/dev/null || true
done
# Ad hoc, no entitlements: not the "Kleoth Self-Signed" identity your grants belong to.
codesign --force --sign - "$APP" >/dev/null 2>&1
cp -R "$DIR/smoke/fixture" "$WORK/data"   # a copy: whatever the app writes stays in $WORK
forget_demo_identity                      # a fresh copy: no shortcut set, so the recorder shows its label

# --- "another Mac": every build folder the binary could fall back to, out of the way ---
while IFS= read -r ROOT; do
  [ -e "$ROOT" ] || continue
  if [ -e "$ROOT.smoke-aside" ]; then
    echo "smoke: $ROOT.smoke-aside exists (an interrupted run?): move it back to $ROOT or delete it" >&2
    exit 1
  fi
  mv "$ROOT" "$ROOT.smoke-aside"
  HIDDEN+=("$ROOT")
  echo "smoke: moved $ROOT aside"
done < <(strings "$APP/Contents/MacOS/Kleoth" | grep -E '^/.*/\.build/' | sed -E 's#(/\.build)/.*#\1#' | sort -u)

# --- run ---
touch "$WORK/started"
"$APP/Contents/MacOS/Kleoth" -KleothDemo "$WORK/data" -KleothDemoFilm "$FILM" -KleothDemoScript smoke >"$LOG" 2>&1 &
PID=$!
STATUS=0
for _ in $(seq 1 180); do                  # the director's own watchdog fires at 150 s
  kill -0 "$PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$PID" 2>/dev/null; then
  echo "demo: smoke failed: still running after 180 s" >>"$LOG"
  kill -9 "$PID" 2>/dev/null || true
fi
wait "$PID" 2>/dev/null || STATUS=$?
PID=""

grep '^demo:' "$LOG" || true
if [ "$STATUS" -eq 0 ] && grep -q '^demo: smoke passed' "$LOG"; then
  echo "smoke: PASSED ($(basename "$SRC"), $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SRC/Contents/Info.plist"))"
  exit 0
fi

echo "smoke: FAILED (exit status $STATUS)" >&2
grep -v '^demo:' "$LOG" | tail -20 >&2 || true
# The crash macOS recorded for this run, if any: its reason and the fatalError message.
# ReportCrash writes it several seconds after the process dies; none comes for a failed check.
REPORT=""
if [ "$STATUS" -gt 128 ]; then
  for _ in $(seq 1 15); do
    REPORT="$(find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -name 'Kleoth*.ips' -newer "$WORK/started" 2>/dev/null | head -1)"
    [ -n "$REPORT" ] && break
    sleep 1
  done
fi
if [ -n "$REPORT" ]; then
  echo "smoke: crash report $REPORT" >&2
  grep -oE '"type" *: *"EXC_[A-Z_]+"|"signal" *: *"SIG[A-Z]+"' "$REPORT" | head -2 | sed 's/^/    /' >&2 || true
  grep -oE '(Fatal error|Assertion failed|Precondition failed)[^"]*' "$REPORT" | head -3 | sed 's/^/    /' >&2 || true
fi
exit 1
