#!/usr/bin/env bash
# The pill's film check: does any phase that has content ever SETTLE empty?
#
# Usage:  bash app/pill-film-check.sh [--quick] [out-dir]
#   out-dir   where the frames, sheets and logs go, always kept. Without it a fresh temp folder is
#             used, deleted when every film passes and kept (its path printed) when one fails.
#   --quick   only the two films CI runs (~30 s): a meeting stopped from its bar with the pointer left
#             on the pill, and a meeting starting inside a sink.
#
# Runs the real pill (`pillsandbox --film --check-content`) through the flows that have rendered an
# empty capsule before, on every edge: a meeting stopped from its bar's Stop with the pointer left on
# the pill and a long save (the 2026-11-19 report: the dock peeked out of the collapse with no
# fields), the same through the stop suggestion, a dictation, a dictation over a meeting, a meeting
# starting just as a dictation's pill folds away (its bar came up with no dot, timer or Stop), the
# dock's own starts, the menu held over a confirmation as it collapses, faults and an offer, a chord
# inside a sink, and a drag — 21 films, about 5 min. A film fails (`contentCheck` in
# app/Sources/pillsandbox/main.swift) when a settled frame of a phase with content has nothing drawn
# inside the capsule, a transition never settles, a capture's bar is due and not on screen, or no
# frame was judged at all. A film that crashes or runs past FILM_TIMEOUT seconds is reported as such.
# PILL_TRACE=1 also turns the pill trace on for the films (`log show … category == "PillTrace"`).
#
# The pill shows on screen for each film but reads no real pointer and sends no events outside its
# own window; placement is the sandbox's own defaults suite, never the app's.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"     # the app/ package directory
QUICK=0
if [ "${1:-}" = "--quick" ]; then QUICK=1; shift; fi
KEEP=1
if [ -n "${1:-}" ]; then
  OUT="$1"
else
  OUT="$(mktemp -d "${TMPDIR:-/tmp}/kleoth-pill-films.XXXXXX")"; KEEP=0
fi
mkdir -p "$OUT"
FILM_TIMEOUT="${FILM_TIMEOUT:-90}"
swift build --package-path "$DIR" --product pillsandbox >"$OUT/build.log" 2>&1 \
  || { tail -n 30 "$OUT/build.log" >&2; echo "film check: build failed ($OUT/build.log)" >&2; exit 1; }
SANDBOX="${PILLSANDBOX:-$DIR/.build/debug/pillsandbox}"   # PILLSANDBOX: another binary (the script's own test)

FAILED=0
COUNT=0
film() {   # film <name> <args…>
  local name="$1"; shift
  COUNT=$((COUNT + 1))
  "$SANDBOX" --film "$OUT/$name" --fps 15 --check-content "$@" ${PILL_TRACE:+-KleothPillTrace YES} >"$OUT/$name.log" 2>&1 &
  local pid=$!
  ( sleep "$FILM_TIMEOUT"; kill -9 "$pid" 2>/dev/null && echo timeout >"$OUT/$name.timeout" ) 2>/dev/null &
  local watchdog=$!
  wait "$pid"; local status=$?
  pkill -P "$watchdog" 2>/dev/null; kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
  local report="$OUT/$name/content-check.txt"
  if [ "$status" -eq 0 ]; then
    echo "ok      $name — $(sed -n 1p "$report" 2>/dev/null | sed "s/^content check: //")"
    return
  fi
  FAILED=1
  if [ -f "$OUT/$name.timeout" ]; then
    echo "TIMEOUT $name — still running after ${FILM_TIMEOUT}s, killed; log: $OUT/$name.log"
  elif [ "$status" -gt 128 ]; then
    echo "CRASH   $name — killed by signal $((status - 128)); log: $OUT/$name.log"
    tail -n 5 "$OUT/$name.log" | sed 's/^/          /'
  elif [ "$status" -eq 1 ] && [ -f "$report" ]; then
    echo "FAIL    $name — $report"
    sed -n '1,4p' "$report" | sed 's/^/          /'
  else
    echo "ERROR   $name — exit $status, no content report; log: $OUT/$name.log"
    tail -n 5 "$OUT/$name.log" | sed 's/^/          /'
  fi
}

# The report: Stop on the meeting bar, the pointer left on the pill, a long save, the confirmation
# collapsing under the pointer (the dock peeks out of the sink).
stop_bar() {   # stop_bar <edge> <save seconds>
  film "stop-bar-$1" --edge "$1" --backdrop meeting --save-seconds "$2" \
    --sequence "meeting@1,hover:stop@0.4,click:stop@$(($2 + 6)),wait:1.2"
}
# A meeting whose bar rises inside the sink of a dictation's "done" (it auto-hides after 1 s; the
# hold ends that much later, give or take a frame at 60 fps): the hot-microphone case.
capture_in_sink() {   # capture_in_sink <ms>
  film "capture-in-sink-$1ms" --fps 60 --edge bottom --backdrop idle \
    --sequence "idle@1,listening@1,done@$(printf "1.%02d" $(($1 / 10))),backdrop:meeting@2.5"
}

if [ "$QUICK" -eq 1 ]; then
  stop_bar top 3
  capture_in_sink 60
else
  for edge in top bottom left right; do
    stop_bar "$edge" 8
    # The same stop through the call-ended suggestion.
    film "stop-suggestion-$edge" --edge "$edge" --backdrop meeting --save-seconds 4 \
      --sequence "meeting@1,stopoffer@1,hover:label@0.4,perform:acceptStop@10,wait:1.2"
    # A dictation from the resting pill.
    film "dictation-$edge" --edge "$edge" \
      --sequence "idle@1,armed@0.3,listening@1.5,transcribing@1,polishing@1,done@1.5,idle@1"
  done
  for ms in 30 60 90; do capture_in_sink "$ms"; done
  # A dictation over a meeting, then its save (the design's phase-1 film).
  film "meeting-dictation" --edge bottom --backdrop meeting \
    --sequence "meeting@1,armed@0.3,listening@1.2,transcribing@0.8,done@1.4,meeting@1,saving@1.5,meetingsaved@1,idle@1"
  # A new chord landing inside a sink (done → idle), then a whole dictation.
  film "chord-in-sink" --edge bottom \
    --sequence "idle@1,listening@1,done@1.02,armed@0.3,listening@1.2,done@1.5,idle@1"
  # Starts from the dock: a meeting and a screen recording, stopped from their bars.
  film "dock-starts" --edge bottom \
    --sequence "idle@1,peek@0.8,hover:meet@0.4,click:meet@2,unpeek@0.2,hover:stop@0.4,click:stop@6.5,unpeek@1,peek@0.8,hover:rec@0.4,click:rec@2,unpeek@0.2,hover:stop@0.4,click:stop@6.5,unpeek@1"
  # The menu held open over "Meeting saved" when it auto-hides: it collapses straight onto the dock.
  film "menu-over-confirmation" --edge bottom \
    --sequence "idle@1,meetingsaved@0.5,menu:open@4.6,menu:close@1.2"
  # Faults and an offer, sticky until replaced.
  film "faults-offer" --edge right \
    --sequence "idle@1,failed@1.5,kept@1.5,idle@1,offer@1.5,hidden@0.6,idle@1"
  # A drag of the meeting bar and of the dock.
  film "drag" --edge bottom --backdrop meeting \
    --sequence "meeting@1,press:center@0.2,move:240:0@1,release@1,backdrop:idle@0.5,idle@1,peek@0.8,press:center@0.2,move:-200:0@1,release@1.2"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "film check: FAILED — frames, sheets and logs kept in $OUT"
  exit 1
fi
echo "film check: all $COUNT films passed"
if [ "$KEEP" -eq 1 ]; then echo "  (frames in $OUT)"; else rm -rf "$OUT"; fi
