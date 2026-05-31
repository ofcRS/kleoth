#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Kleoth: Save Latest to Obsidian
# @raycast.mode compact
# @raycast.packageName Kleoth
# @raycast.icon 🪨
# @raycast.argument1 { "type": "text", "placeholder": "Obsidian vault folder path" }
# @raycast.description Copy the latest meeting's summary (or transcript) into an Obsidian vault.

VAULT="$1"
DIR="${KLEOTH_DIR:-$HOME/Kleoth}"

if [ ! -d "$VAULT" ]; then
  echo "Vault folder not found: $VAULT"
  exit 1
fi

latest=$(ls -dt "$DIR"/*/ 2>/dev/null | head -1)
if [ -z "$latest" ]; then
  echo "No meetings found in $DIR"
  exit 1
fi

note="${latest}summary.md"
[ -f "$note" ] || note="${latest}transcript.md"
if [ ! -f "$note" ]; then
  echo "Latest meeting has no summary.md or transcript.md"
  exit 1
fi

dest="$VAULT/Kleoth Meetings"
mkdir -p "$dest"
name=$(basename "$latest")
cp "$note" "$dest/$name.md"
echo "Saved $(basename "$note") → $dest/$name.md"
