#!/usr/bin/env bash
# Sign Kleoth.app inside-out: Sparkle's helpers, then Sparkle.framework, then the app.
#
# Usage:  bash app/codesign-app.sh <Kleoth.app> <identity|-> [--keychain <path>] [--hardened]
#         --keychain  where the identity lives (make-app.sh: the "Kleoth Self-Signed" keychain)
#         --hardened  the Developer ID tier (make-dmg.sh): hardened runtime + secure timestamp
#
# Every nested bundle is signed on its own, deepest first, with the app's identity: an update is
# accepted when its signature satisfies the installed app's designated requirement, and TCC grants
# are bound to the same identity. Never `codesign --deep` over the app: it signs outside-in and
# re-signs Sparkle's Downloader.xpc without its entitlements (Sparkle's sandboxing guide lists the
# order used here). Kleoth is not sandboxed, so the two XPC services are unused, but they ship
# inside Sparkle.framework and are signed like the rest.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"     # the app/ package directory
[ $# -ge 2 ] || { echo "usage: $0 <Kleoth.app> <identity|-> [--keychain <path>] [--hardened]" >&2; exit 64; }
APP="$1"; IDENTITY="$2"; shift 2
FLAGS=(--force --sign "$IDENTITY")
while [ $# -gt 0 ]; do
    case "$1" in
        --keychain) FLAGS+=(--keychain "$2"); shift 2 ;;
        --hardened) FLAGS+=(--options runtime --timestamp); shift ;;
        *) echo "codesign-app: unknown option $1" >&2; exit 64 ;;
    esac
done

FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
    V="$FW/Versions/$(readlink "$FW/Versions/Current")"
    for NESTED in "$V/XPCServices/Installer.xpc" "$V/XPCServices/Downloader.xpc" "$V/Autoupdate" "$V/Updater.app"; do
        [ -e "$NESTED" ] || { echo "error: $NESTED is missing: did Sparkle's layout change?" >&2; exit 1; }
    done
    codesign "${FLAGS[@]}" "$V/XPCServices/Installer.xpc"
    codesign "${FLAGS[@]}" --preserve-metadata=entitlements "$V/XPCServices/Downloader.xpc"
    codesign "${FLAGS[@]}" "$V/Autoupdate"
    codesign "${FLAGS[@]}" "$V/Updater.app"
    codesign "${FLAGS[@]}" "$FW"
fi
codesign "${FLAGS[@]}" --entitlements "$DIR/bundle/Kleoth.entitlements" "$APP"
