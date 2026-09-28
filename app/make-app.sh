#!/usr/bin/env bash
# Build KleothApp and package it as a runnable, code-signed macOS .app bundle.
#
# Usage:  bash app/make-app.sh [debug|release]      (default: debug; installs to /Applications)
#         KLEOTH_NO_INSTALL=1 bash app/make-app.sh release   (app/dist/Kleoth.app only)
# Then:   open app/dist/Kleoth.app
#
# Ad-hoc signing (`--sign -`) is enough to run locally and trigger the
# microphone permission prompt. For distribution, re-sign with a Developer ID +
# hardened runtime and notarize (see BUILD-APP.md).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"     # the app/ package directory
CONFIG="${1:-debug}"

# SwiftPM's `Bundle.module` finds a resource bundle only at the .app ROOT or in THIS Mac's build
# folder, and calls fatalError otherwise: fine here, a crash on every other Mac (#17 at launch; the
# vendored KeyboardShortcuts in Settings → General). App code loads resources through
# `KleothAssets.resources` (Contents/Resources) instead.
if grep -rnE 'Bundle\.module|bundle: *\.module' "$DIR/Sources" --include='*.swift' | grep -vE '^[^:]+:[0-9]+: *//'; then
    echo "error: Bundle.module in app code — use KleothAssets.url(forResource:withExtension:) (issue #17)" >&2
    exit 1
fi

echo "==> swift build ($CONFIG)"
swift build --package-path "$DIR" -c "$CONFIG"

BIN="$DIR/.build/$CONFIG/KleothApp"
APP="$DIR/dist/Kleoth.app"

# The same trap in any DEPENDENCY: a live `Bundle.module` leaves this Mac's build path in the binary
# (a release build strips the unused ones). Allowed: swift-transformers' Hub, reached only for a
# tokenizer config without `tokenizer_class`, which WhisperKit's Whisper configs always have.
if [ "$CONFIG" = release ]; then
    LIVE="$(strings "$BIN" | grep -E '/\.build/.*\.bundle$' | grep -v '/swift-transformers_Hub\.bundle$' || true)"
    if [ -n "$LIVE" ]; then
        echo "error: Bundle.module is live for (a crash on every other Mac):" >&2
        echo "$LIVE" | sed 's/^/    /' >&2
        exit 1
    fi
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/bundle/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/Kleoth"

# App icon (classic .icns; CFBundleIconFile = "Kleoth" in Info.plist).
if [ -f "$DIR/bundle/Kleoth.icns" ]; then
    cp "$DIR/bundle/Kleoth.icns" "$APP/Contents/Resources/Kleoth.icns"
    echo "    bundled app icon Kleoth.icns"
fi

# Every SwiftPM resource bundle goes in Contents/Resources, where `KleothAssets.resources` and the
# vendored KeyboardShortcuts look (and where a signed app's resources belong). These two are required.
for NAME in KleothApp_KleothApp KeyboardShortcuts_KeyboardShortcuts; do
    if [ ! -d "$DIR/.build/$CONFIG/$NAME.bundle" ]; then
        echo "error: $NAME.bundle is missing — the app would run without its images or strings" >&2
        exit 1
    fi
done
for RESBUNDLE in "$DIR/.build/$CONFIG/"*.bundle; do
    cp -R "$RESBUNDLE" "$APP/Contents/Resources/"
    echo "    bundled resources $(basename "$RESBUNDLE")"
done

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

# A release build must open its screens with this Mac's build folders out of reach before it
# replaces /Applications/Kleoth.app or goes into a DMG: a crash there is a crash on every Mac
# that did not build it (#17 at launch, #22 in Settings). ~20 s; app/smoke-test.sh.
if [ "$CONFIG" = release ]; then
    echo "==> smoke test"
    bash "$DIR/smoke-test.sh" "$APP"
fi

# Install to /Applications so it behaves like a normal, double-clickable app — unless
# KLEOTH_NO_INSTALL=1 (CI, or a branch build you only want to smoke-test).
if [ "${KLEOTH_NO_INSTALL:-}" = 1 ]; then
    echo "==> done. $APP (not installed: KLEOTH_NO_INSTALL=1)"
    exit 0
fi
INSTALLED="/Applications/Kleoth.app"
echo "==> installing to $INSTALLED"
rm -rf "$INSTALLED"
cp -R "$APP" "$INSTALLED"

echo "==> done. Installed at $INSTALLED"
echo "    launch with:  open \"$INSTALLED\""
