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

echo "==> codesigning"
KC="$HOME/Library/Keychains/kleoth-codesign.keychain-db"
IDENTITY="Kleoth Self-Signed"
if security find-identity "$KC" 2>/dev/null | grep -q "$IDENTITY"; then
    security unlock-keychain -p kleoth-codesign "$KC" 2>/dev/null || true
    codesign --force --sign "$IDENTITY" --keychain "$KC" --entitlements "$DIR/bundle/Kleoth.entitlements" "$APP"
    echo "    signed with stable identity '$IDENTITY' (TCC grants persist across rebuilds)"
else
    codesign --force --sign - --entitlements "$DIR/bundle/Kleoth.entitlements" "$APP"
    echo "    signed ad-hoc — run 'bash $DIR/setup-signing.sh' for a stable identity"
fi
codesign -dv "$APP" 2>&1 | sed -n '1,2p' || true

# Install to /Applications so it behaves like a normal, double-clickable app.
INSTALLED="/Applications/Kleoth.app"
echo "==> installing to $INSTALLED"
rm -rf "$INSTALLED"
cp -R "$APP" "$INSTALLED"

echo "==> done. Installed at $INSTALLED"
echo "    launch with:  open \"$INSTALLED\""
