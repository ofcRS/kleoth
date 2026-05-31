#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Kleoth: Open Latest Transcript
# @raycast.mode silent
# @raycast.packageName Kleoth
# @raycast.icon 📄
# @raycast.description Open the most recent meeting's transcript.md.

DIR="${KLEOTH_DIR:-$HOME/Kleoth}"
latest=$(ls -dt "$DIR"/*/ 2>/dev/null | head -1)
if [ -z "$latest" ]; then
  echo "No meetings found in $DIR"
  exit 1
fi
note="${latest}transcript.md"
if [ ! -f "$note" ]; then
  echo "No transcript.md in $(basename "$latest")"
  exit 1
fi
open "$note"
