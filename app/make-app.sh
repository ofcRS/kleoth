#!/usr/bin/env bash
# Build KleothApp and package it as a runnable, code-signed macOS .app bundle.
#
# Usage:  bash app/make-app.sh [debug|release]      (default: debug)
# Then:   open app/dist/Kleoth.app
#
# Ad-hoc signing (`--sign -`) is enough to run locally and trigger the
# microphone permission prompt. For distribution, re-sign with a Developer ID +
# hardened runtime and notarize (see BUILD-APP.md).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"     # the app/ package directory
CONFIG="${1:-debug}"

echo "==> swift build ($CONFIG)"
swift build --package-path "$DIR" -c "$CONFIG"

BIN="$DIR/.build/$CONFIG/KleothApp"
APP="$DIR/dist/Kleoth.app"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/bundle/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/Kleoth"

echo "==> codesigning (ad-hoc)"
codesign --force --sign - --entitlements "$DIR/bundle/Kleoth.entitlements" "$APP"
codesign -dv "$APP" 2>&1 | sed -n '1,2p' || true

echo "==> done. Launch with:  open \"$APP\""
