#!/usr/bin/env bash
# The in-app updater end to end, without the installed Kleoth (docs/plans/2026-11-16-updater.md §6).
#
# Usage:  bash app/updater-e2e.sh [path/to/Kleoth.app]     (default: app/dist/Kleoth.app)
#
# Two copies of the given app under their own bundle id (dev.kleoth.updateprobe), signed like the
# real one ("Kleoth Self-Signed" if this Mac has it, else ad hoc): an "installed" one at the app's
# build B, and an update at B+1 in a DMG. A throwaway EdDSA key (never the release key) signs the
# DMG; app/make-appcast.ts writes the feed; python serves both on 127.0.0.1. Then `updatecheck`
# (Sparkle's real updater with a printing user driver, loading the COPY's Sparkle.framework, so
# the installer that runs is the one Kleoth ships):
#   1. Sparkle orders build B before B+1;
#   2. refuses a feed whose signature is for other bytes, and leaves the copy as it was;
#   3. finds the update, downloads it, and its installer extracts it, validates it (EdDSA against
#      the copy's SUPublicEDKey, code signature against the copy's designated requirement) and,
#      the copy not running, installs it: the copy is then build B+1, verifies, is not quarantined.
# Nothing is launched from either copy and nothing relaunches. The copies, the key, the feed and
# Sparkle's state for dev.kleoth.updateprobe (defaults, caches) are deleted afterwards. ~1 min.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"     # the app/ package directory
ROOT="$(cd "$DIR/.." && pwd)"
SRC="${1:-$DIR/dist/Kleoth.app}"
[ -x "$SRC/Contents/MacOS/Kleoth" ] || { echo "e2e: no app at $SRC (run make-app.sh release first)" >&2; exit 1; }
[ -d "$SRC/Contents/Frameworks/Sparkle.framework" ] || { echo "e2e: $SRC has no Sparkle.framework" >&2; exit 1; }
ID=dev.kleoth.updateprobe
PORT="${KLEOTH_E2E_PORT:-8765}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kleoth-update-e2e.XXXXXX")"
PROBE="$DIR/.build/debug/updatecheck"
SERVER=""

cleanup() {
  [ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null || true
  defaults delete "$ID" >/dev/null 2>&1 || true
  # Sparkle's state for the copy's id, and the probe's own URL cache (named after the binary).
  rm -rf "$HOME/Library/Caches/$ID" "$(getconf DARWIN_USER_CACHE_DIR)$ID" "$WORK" \
         "$HOME/Library/Caches/updatecheck" "$HOME/Library/HTTPStorages/updatecheck"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "==> probe"
swift build --package-path "$DIR" --product updatecheck >/dev/null

echo "==> throwaway EdDSA key (not the release key)"
KEY="$WORK/e2e-ed25519.key"
PUB="$(KEYFILE="$KEY" bun -e '
  const { generateKeyPairSync } = require("node:crypto");
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  // Sparkle key files hold the base64 of the 32-byte seed (the PKCS#8 DER tail).
  require("node:fs").writeFileSync(process.env.KEYFILE, privateKey.export({ format: "der", type: "pkcs8" }).subarray(16).toString("base64"));
  console.log(publicKey.export({ format: "der", type: "spki" }).subarray(12).toString("base64"));
')"

KC="$HOME/Library/Keychains/kleoth-codesign.keychain-db"
SIGN=(-)
if security find-identity "$KC" 2>/dev/null | grep -q "Kleoth Self-Signed"; then
  security unlock-keychain -p kleoth-codesign "$KC" 2>/dev/null || true
  SIGN=("Kleoth Self-Signed" --keychain "$KC")
fi

BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$SRC/Contents/Info.plist")"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SRC/Contents/Info.plist")"
NEXT=$((BUILD + 1))

make_copy() {   # <dest.app> <short version> <build>
  ditto "$SRC" "$1"
  plutil -replace CFBundleIdentifier -string "$ID" "$1/Contents/Info.plist"
  plutil -replace CFBundleShortVersionString -string "$2" "$1/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$3" "$1/Contents/Info.plist"
  plutil -replace SUPublicEDKey -string "$PUB" "$1/Contents/Info.plist"
  bash "$DIR/codesign-app.sh" "$1" "${SIGN[@]}" >/dev/null 2>&1
  codesign --verify --deep --strict "$1"
}

echo "==> copies: installed $SHORT ($BUILD), update $SHORT-e2e ($NEXT), signed ${SIGN[0]}"
mkdir -p "$WORK/installed" "$WORK/stage" "$WORK/www"
make_copy "$WORK/installed/Kleoth.app" "$SHORT" "$BUILD"
make_copy "$WORK/stage/Kleoth.app" "$SHORT-e2e" "$NEXT"
ln -s /Applications "$WORK/stage/Applications"
DMG="$WORK/www/Kleoth-$SHORT-e2e.dmg"
hdiutil create -volname Kleoth -srcfolder "$WORK/stage" -fs HFS+ -format UDZO -ov "$DMG" -quiet

echo "==> feed (app/make-appcast.ts)"
printf '### End to end\n\n- A **test** update.\n' > "$WORK/notes.md"
bun "$DIR/make-appcast.ts" --dmg "$DMG" --out "$WORK/www/appcast.xml" --previous none \
  --download-base "http://127.0.0.1:$PORT/" --notes "$WORK/notes.md" --ed-key-file "$KEY" | sed 's/^/    /'
# The same feed with a valid signature of other bytes: Sparkle must refuse it.
OTHER="$("$DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update" --ed-key-file "$KEY" -p "$WORK/notes.md")"
sed -E "s#sparkle:edSignature=\"[^\"]+\"#sparkle:edSignature=\"$OTHER\"#" "$WORK/www/appcast.xml" > "$WORK/www/appcast-tampered.xml"

python3 -I -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/www" >"$WORK/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$PORT/appcast.xml" >/dev/null 2>&1 && break; sleep 0.1; done

# The copy's own Sparkle.framework, so the installer that runs is the one Kleoth ships.
probe() { DYLD_FRAMEWORK_PATH="$WORK/installed/Kleoth.app/Contents/Frameworks" "$PROBE" "$WORK/installed/Kleoth.app" "$@"; }
FAIL=0
check() { if [ "$1" = ok ]; then echo "    ✓ $2"; else echo "    ✗ $2" >&2; FAIL=1; fi; }

echo "==> 1. version order"
ORDER="$("$PROBE" --compare "$BUILD" "$NEXT")"
[ "$ORDER" = "$BUILD < $NEXT" ] && check ok "Sparkle: $ORDER" || check no "Sparkle: $ORDER"

echo "==> 2. a signature for other bytes is refused"
if OUT="$(probe --feed "http://127.0.0.1:$PORT/appcast-tampered.xml" 2>&1)"; then
  check no "the tampered feed was accepted"
else
  grep -qiE "signature|EdDSA" <<<"$OUT" && check ok "refused on its signature" || check no "failed, but not on the signature"
fi
sed "s/^/      /" <<<"$OUT"
WAS="$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$WORK/installed/Kleoth.app/Contents/Info.plist")"
[ "$WAS" = "$BUILD" ] && check ok "the installed copy is untouched (build $WAS)" || check no "the installed copy changed to build $WAS"

echo "==> 3. found, downloaded, validated, installed over the copy (it is not running: no prompt)"
if OUT="$(probe --feed "http://127.0.0.1:$PORT/appcast.xml" 2>&1)" && grep -q "update found: $SHORT-e2e" <<<"$OUT" && grep -q "OK: installed" <<<"$OUT"; then
  check ok "update $SHORT-e2e ($NEXT) installed"
else
  check no "update not installed"
fi
sed "s/^/      /" <<<"$OUT"
NOW="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$WORK/installed/Kleoth.app/Contents/Info.plist" 2>/dev/null || echo none)"
[ "$NOW" = "$NEXT" ] && check ok "the installed copy is build $NOW" || check no "the installed copy is build $NOW, expected $NEXT"
codesign --verify --deep --strict "$WORK/installed/Kleoth.app" 2>/dev/null && check ok "it verifies (--deep --strict)" || check no "its signature does not verify"
if xattr -r "$WORK/installed/Kleoth.app" 2>/dev/null | grep -q com.apple.quarantine; then check no "it is quarantined"; else check ok "no quarantine"; fi

[ "$FAIL" = 0 ] && { echo "e2e: PASSED"; exit 0; }
echo "e2e: FAILED" >&2
exit 1
