#!/usr/bin/env bash
# The pill's film check: does any phase that has content ever SETTLE empty?
#
# Usage:  bash app/pill-film-check.sh [out-dir]     (default: a fresh temp folder, kept on failure)
#
# Runs the real pill (`pillsandbox --film --check-content`) through the flows that have rendered an
# empty capsule before, on every edge: a meeting stopped from its bar's Stop with the pointer left on
# the pill and a long save (the 2026-11-19 report: the dock peeked out of the collapse with no
# fields), the same through the stop suggestion, a dictation, a dictation over a meeting, the dock's
# own starts, faults and offers, a new chord landing in a sink, and a drag. Each film fails when a
# settled frame of a phase with content has nothing drawn inside the capsule (`contentCheck` in
# app/Sources/pillsandbox/main.swift). Mid-transition frames are not judged.
#
# The pill shows on screen for each film (about 5 min in all) but reads no real pointer and sends no
# events outside its own window; placement is the sandbox's own defaults suite, never the app's.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"     # the app/ package directory
OUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/kleoth-pill-films.XXXXXX")}"
mkdir -p "$OUT"
swift build --package-path "$DIR" --product pillsandbox >/dev/null || { echo "film check: build failed" >&2; exit 1; }
SANDBOX="$DIR/.build/debug/pillsandbox"

FAILED=0
film() {   # film <name> <args…>
  local name="$1"; shift
  if "$SANDBOX" --film "$OUT/$name" --fps 15 --check-content "$@" >"$OUT/$name.log" 2>&1; then
    echo "ok    $name"
  else
    FAILED=1
    echo "EMPTY $name — $OUT/$name/content-check.txt"
    sed -n '1,4p' "$OUT/$name/content-check.txt" 2>/dev/null | sed 's/^/        /'
  fi
}

for edge in top bottom left right; do
  # The report: Stop on the meeting bar, the pointer left on the pill, a long save, the confirmation
  # collapsing under the pointer (the dock peeks out of the sink).
  film "stop-bar-$edge" --edge "$edge" --backdrop meeting --save-seconds 8 \
    --sequence "meeting@1,hover:stop@0.4,click:stop@14,wait:1.2"
  # The same stop through the call-ended suggestion.
  film "stop-suggestion-$edge" --edge "$edge" --backdrop meeting --save-seconds 4 \
    --sequence "meeting@1,stopoffer@1,hover:label@0.4,perform:acceptStop@10,wait:1.2"
  # A dictation from the resting pill.
  film "dictation-$edge" --edge "$edge" \
    --sequence "idle@1,armed@0.3,listening@1.5,transcribing@1,polishing@1,done@1.5,idle@1"
done

# A dictation over a meeting, then its save (the design's phase-1 film).
film "meeting-dictation" --edge bottom --backdrop meeting \
  --sequence "meeting@1,armed@0.3,listening@1.2,transcribing@0.8,done@1.4,meeting@1,saving@1.5,meetingsaved@1,idle@1"
# A new chord landing inside a sink (done → idle), then a whole dictation.
film "chord-in-sink" --edge bottom \
  --sequence "idle@1,listening@1,done@1.02,armed@0.3,listening@1.2,done@1.5,idle@1"
# Starts from the dock: a meeting and a screen recording, stopped from their bars.
film "dock-starts" --edge bottom \
  --sequence "idle@1,peek@0.8,hover:meet@0.4,click:meet@2,unpeek@0.2,hover:stop@0.4,click:stop@6.5,unpeek@1,peek@0.8,hover:rec@0.4,click:rec@2,unpeek@0.2,hover:stop@0.4,click:stop@6.5,unpeek@1"
# Faults and an offer, sticky until replaced.
film "faults-offer" --edge right \
  --sequence "idle@1,failed@1.5,kept@1.5,idle@1,offer@1.5,hidden@0.6,idle@1"
# A drag of the dock and of the meeting bar.
film "drag" --edge bottom --backdrop meeting \
  --sequence "meeting@1,press:center@0.2,move:240:0@1,release@1,backdrop:idle@0.5,idle@1,peek@0.8,press:center@0.2,move:-200:0@1,release@1.2"

if [ "$FAILED" -ne 0 ]; then
  echo "film check: FAILED — frames, sheets and logs in $OUT"
  exit 1
fi
echo "film check: all films passed ($OUT)"
