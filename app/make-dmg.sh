#!/usr/bin/env bash
# Package Kleoth into a distributable, signed .dmg (drag-to-Applications).
#
# Usage:  bash app/make-dmg.sh
# Output: app/dist/Kleoth-<version>.dmg  (version from bundle/Info.plist)
#
# Signing tiers, auto-detected:
#   1. Public release — set KLEOTH_SIGN_IDENTITY to a "Developer ID Application:
#      …" identity (requires the Apple Developer Program). The app is re-signed
#      with the hardened runtime + secure timestamp; if KLEOTH_NOTARY_PROFILE is
#      also set (created via `xcrun notarytool store-credentials`), the DMG is
#      notarized and stapled — Gatekeeper-clean on any Mac.
#   2. Default — the local "Kleoth Self-Signed" identity (falling back to
#      ad-hoc). Installs fine on THIS Mac; on other Macs Gatekeeper blocks the
#      first launch until right-click → Open (no Developer ID to verify).
#
# PKG was considered and rejected: per the distribution research, a DMG is the
# normal vehicle for a menu-bar app; PKG only earns its keep for enterprise/MDM.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"      # the app/ package directory
DIST="$DIR/dist"
APP="$DIST/Kleoth.app"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DIR/bundle/Info.plist")"
VOLNAME="Kleoth"
OUT_DMG="$DIST/Kleoth-$VERSION.dmg"

# ---------------------------------------------------------------- 1. build app
# make-app.sh builds, signs (self-signed tier), and refreshes /Applications —
# the dist copy is what gets packaged, so the DMG always matches what runs.
echo "==> building release app bundle"
bash "$DIR/make-app.sh" release

# ------------------------------------------------- 2. optional Developer ID re-sign
if [ -n "${KLEOTH_SIGN_IDENTITY:-}" ]; then
    echo "==> re-signing for distribution: $KLEOTH_SIGN_IDENTITY"
    codesign --force --deep --sign "$KLEOTH_SIGN_IDENTITY" \
        --options runtime --timestamp \
        --entitlements "$DIR/bundle/Kleoth.entitlements" "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "    app signature verifies"

# ---------------------------------------------------------------- 3. staging
STAGE="$DIST/dmg-staging"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Kleoth.app"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/Read Me.txt" <<'EOF'
Kleoth — local-first meeting recorder
=====================================

Install: drag Kleoth.app onto the Applications folder, then launch it from
Applications. Kleoth lives in the menu bar (the lyre icon).

Requirements: macOS 14.4 or later, Apple Silicon recommended.

First launch:
• If macOS says the app is from an unidentified developer, right-click
  Kleoth.app and choose "Open" (needed once; this build is not notarized).
• Kleoth will ask for Microphone and System Audio Recording permission —
  both are needed to capture you AND the other meeting participants.
• If a Keychain dialog appears, click "Always Allow" (asked at most once).
• The on-device transcription model (~600 MB) downloads on first use, then
  everything transcribes offline.

Your data: every meeting is written as plain files (audio, transcript.md,
summary.md, JSON) to ~/Kleoth — yours to keep, grep, or sync.

Optional: add an ElevenLabs key (cloud transcription) and/or an OpenRouter
key (summaries) in Settings.
EOF

# ----------------------------------------------------------------- 4. build DMG
# UDRW first so the volume icon can be set on the mounted root, then convert
# to a compressed read-only UDZO for distribution.
TMP_DMG="$DIST/Kleoth-tmp.dmg"
rm -f "$TMP_DMG" "$OUT_DMG"

echo "==> creating DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -fs HFS+ \
    -format UDRW "$TMP_DMG" -quiet

MOUNT_DIR="$(hdiutil attach "$TMP_DMG" -readwrite -noverify -noautoopen \
    | awk -F'\t' 'END{print $NF}')"
if [ -f "$DIR/bundle/Kleoth.icns" ] && command -v SetFile >/dev/null 2>&1; then
    cp "$DIR/bundle/Kleoth.icns" "$MOUNT_DIR/.VolumeIcon.icns"
    SetFile -a C "$MOUNT_DIR" 2>/dev/null \
        && echo "    volume icon set" \
        || echo "    volume icon skipped (SetFile failed)"
fi
hdiutil detach "$MOUNT_DIR" -quiet
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -ov \
    -o "$OUT_DMG" -quiet
rm -f "$TMP_DMG"

# ------------------------------------------------------------------ 5. sign DMG
echo "==> signing DMG"
KC="$HOME/Library/Keychains/kleoth-codesign.keychain-db"
if [ -n "${KLEOTH_SIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$KLEOTH_SIGN_IDENTITY" --timestamp "$OUT_DMG"
elif security find-identity "$KC" 2>/dev/null | grep -q "Kleoth Self-Signed"; then
    security unlock-keychain -p kleoth-codesign "$KC" 2>/dev/null || true
    codesign --force --sign "Kleoth Self-Signed" --keychain "$KC" "$OUT_DMG"
else
    codesign --force --sign - "$OUT_DMG"
fi

# ------------------------------------------------------- 6. optional notarization
if [ -n "${KLEOTH_NOTARY_PROFILE:-}" ] && [ -n "${KLEOTH_SIGN_IDENTITY:-}" ]; then
    echo "==> notarizing (profile: $KLEOTH_NOTARY_PROFILE)"
    xcrun notarytool submit "$OUT_DMG" --keychain-profile "$KLEOTH_NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUT_DMG"
    echo "    notarized + stapled"
elif [ -n "${KLEOTH_SIGN_IDENTITY:-}" ]; then
    echo "    NOTE: signed with Developer ID but NOT notarized — set"
    echo "    KLEOTH_NOTARY_PROFILE to notarize + staple for public release."
fi

# -------------------------------------------------------------------- 7. report
echo "==> verifying"
hdiutil verify "$OUT_DMG" -quiet && echo "    image checksum OK"
if spctl --assess --type open --context context:primary-signature "$OUT_DMG" 2>/dev/null; then
    echo "    Gatekeeper: ACCEPTED (notarized)"
else
    echo "    Gatekeeper: not notarized — other Macs need right-click → Open (expected for the self-signed tier)"
fi

SIZE="$(du -h "$OUT_DMG" | cut -f1 | tr -d ' ')"
echo ""
echo "==> done: $OUT_DMG  (v$VERSION, $SIZE)"
shasum -a 256 "$OUT_DMG"
