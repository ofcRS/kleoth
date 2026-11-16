#!/usr/bin/env bash
# The in-app updater end to end, without the installed Kleoth (docs/plans/2026-11-16-updater.md §5).
#
# Usage:  bash app/updater-e2e.sh [path/to/Kleoth.app]     (default: app/dist/Kleoth.app)
#
# Copies of the given app under their own bundle id (dev.kleoth.updateprobe), signed "Kleoth
# Self-Signed" like the real one (required: make-appcast.ts refuses anything else): an "installed"
# one at the app's build B, and updates at B+1 in DMGs. Throwaway EdDSA keys (never the release
# key) sign the DMGs; app/make-appcast.ts writes the feeds; python serves them on 127.0.0.1. Then
# `updatecheck` (Sparkle's real updater with a printing user driver, loading the COPY's
# Sparkle.framework, so the installer that runs is the one Kleoth ships):
#   1. Sparkle orders build B before B+1;
#   2. refuses a feed whose signature is for other bytes, before extracting the DMG;
#   3. refuses an update signed with the right certificate but another EdDSA key (what a stolen
#      "Kleoth Self-Signed" key could produce): with SUVerifyUpdateBeforeExtraction the EdDSA
#      signature is mandatory and the code signature is no fallback for an app without a Team ID;
#   4. finds the real update, downloads it, validates it and, the copy not running, installs it:
#      the copy is then build B+1, verifies, and is not quarantined.
# The copy is checked untouched after 2 and 3. Nothing is launched from any copy and nothing
# relaunches. The copies, the keys, the feeds and Sparkle's state for dev.kleoth.updateprobe
# (defaults, caches) are deleted afterwards. ~1 min.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"     # the app/ package directory
SRC="${1:-$DIR/dist/Kleoth.app}"
[ -x "$SRC/Contents/MacOS/Kleoth" ] || { echo "e2e: no app at $SRC (run make-app.sh release first)" >&2; exit 1; }
[ -d "$SRC/Contents/Frameworks/Sparkle.framework" ] || { echo "e2e: $SRC has no Sparkle.framework" >&2; exit 1; }
KC="$HOME/Library/Keychains/kleoth-codesign.keychain-db"
security find-identity "$KC" 2>/dev/null | grep -q "Kleoth Self-Signed" \
  || { echo "e2e: needs the \"Kleoth Self-Signed\" identity every Kleoth is signed with (this Mac has none)" >&2; exit 1; }
security unlock-keychain -p kleoth-codesign "$KC" 2>/dev/null || true
ID=dev.kleoth.updateprobe
PORT="${KLEOTH_E2E_PORT:-8765}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kleoth-update-e2e.XXXXXX")"
PROBE="$DIR/.build/debug/updatecheck"
SIGN_UPDATE="$DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"
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

new_key() {   # <key file> → prints the public key
  KEYFILE="$1" bun -e '
    const { generateKeyPairSync } = require("node:crypto");
    const { publicKey, privateKey } = generateKeyPairSync("ed25519");
    // Sparkle key files hold the base64 of the 32-byte seed (the PKCS#8 DER tail).
    require("node:fs").writeFileSync(process.env.KEYFILE, privateKey.export({ format: "der", type: "pkcs8" }).subarray(16).toString("base64"));
    console.log(publicKey.export({ format: "der", type: "spki" }).subarray(12).toString("base64"));
  '
}
echo "==> throwaway EdDSA keys (not the release key): the app's, and another"
KEY="$WORK/e2e-ed25519.key";       PUB="$(new_key "$KEY")"
OTHER_KEY="$WORK/other-ed25519.key"; OTHER_PUB="$(new_key "$OTHER_KEY")"

BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$SRC/Contents/Info.plist")"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SRC/Contents/Info.plist")"
NEXT=$((BUILD + 1))

make_copy() {   # <dest.app> <short version> <build> <SUPublicEDKey>
  ditto "$SRC" "$1"
  plutil -replace CFBundleIdentifier -string "$ID" "$1/Contents/Info.plist"
  plutil -replace CFBundleShortVersionString -string "$2" "$1/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$3" "$1/Contents/Info.plist"
  plutil -replace SUPublicEDKey -string "$4" "$1/Contents/Info.plist"
  bash "$DIR/codesign-app.sh" "$1" "Kleoth Self-Signed" --keychain "$KC" >/dev/null 2>&1
  codesign --verify --deep --strict "$1"
}

make_dmg() {   # <stage dir> <dmg>
  ln -s /Applications "$1/Applications"
  hdiutil create -volname Kleoth -srcfolder "$1" -fs HFS+ -format UDZO -ov "$2" -quiet
}

printf '### End to end\n\n- A **test** update.\n' > "$WORK/notes.md"
feed() {   # <dmg> <out.xml> <key file>
  bun "$DIR/make-appcast.ts" --dmg "$1" --out "$2" --previous none \
    --download-base "http://127.0.0.1:$PORT/" --notes "$WORK/notes.md" --ed-key-file "$3" | sed 's/^/    /'
}

echo "==> copies: installed $SHORT ($BUILD); updates $SHORT-e2e ($NEXT), signed \"Kleoth Self-Signed\""
mkdir -p "$WORK/installed" "$WORK/stage" "$WORK/stage-rotated" "$WORK/www"
make_copy "$WORK/installed/Kleoth.app" "$SHORT" "$BUILD" "$PUB"
make_copy "$WORK/stage/Kleoth.app" "$SHORT-e2e" "$NEXT" "$PUB"
make_copy "$WORK/stage-rotated/Kleoth.app" "$SHORT-e2e" "$NEXT" "$OTHER_PUB"
make_dmg "$WORK/stage" "$WORK/www/Kleoth-$SHORT-e2e.dmg"
make_dmg "$WORK/stage-rotated" "$WORK/www/Kleoth-$SHORT-e2e-rotated.dmg"
[ "$(/usr/libexec/PlistBuddy -c 'Print SUVerifyUpdateBeforeExtraction' "$WORK/installed/Kleoth.app/Contents/Info.plist" 2>/dev/null)" = true ] \
  && echo "    the installed copy has SUVerifyUpdateBeforeExtraction" \
  || echo "    NOTE: the installed copy lacks SUVerifyUpdateBeforeExtraction (step 3 is expected to fail)"

echo "==> feeds (app/make-appcast.ts)"
feed "$WORK/www/Kleoth-$SHORT-e2e.dmg" "$WORK/www/appcast.xml" "$KEY"
# Right certificate, another EdDSA key: its own SUPublicEDKey, its DMG signed with that key.
feed "$WORK/www/Kleoth-$SHORT-e2e-rotated.dmg" "$WORK/www/appcast-rotated.xml" "$OTHER_KEY"
# The real feed with a valid signature of other bytes.
WRONG="$("$SIGN_UPDATE" --ed-key-file "$KEY" -p "$WORK/notes.md")"
sed -E "s#sparkle:edSignature=\"[^\"]+\"#sparkle:edSignature=\"$WRONG\"#" "$WORK/www/appcast.xml" > "$WORK/www/appcast-tampered.xml"

python3 -I -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/www" >"$WORK/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$PORT/appcast.xml" >/dev/null 2>&1 && break; sleep 0.1; done

# The copy's own Sparkle.framework, so the installer that runs is the one Kleoth ships.
probe() { DYLD_FRAMEWORK_PATH="$WORK/installed/Kleoth.app/Contents/Frameworks" "$PROBE" "$WORK/installed/Kleoth.app" "$@"; }
FAIL=0
check() { if [ "$1" = ok ]; then echo "    ✓ $2"; else echo "    ✗ $2" >&2; FAIL=1; fi; }
untouched() {
  local now
  now="$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$WORK/installed/Kleoth.app/Contents/Info.plist")"
  [ "$now" = "$BUILD" ] && check ok "the installed copy is untouched (build $now)" || check no "the installed copy changed to build $now"
}
# Sparkle's installer (launchd job <id>-sparkle-updater) outlives a refusal by a moment; a check
# started meanwhile tries to resume it ("Failed to resume installing update").
settle() {
  for _ in $(seq 1 60); do
    launchctl list 2>/dev/null | awk -v l="$ID-sparkle-updater" '$3 == l && $1 != "-" { found = 1 } END { exit !found }' || return 0
    sleep 0.5
  done
}
refused() {   # <feed file> <what>
  local out
  settle
  if out="$(probe --feed "http://127.0.0.1:$PORT/$1" 2>&1)"; then
    check no "$2 was accepted"
  elif grep -q "before unarchiving" <<<"$out"; then
    check ok "$2 refused, before the DMG was opened"
  else
    check no "$2 failed, but not on its EdDSA signature before extraction"
  fi
  sed "s/^/      /" <<<"$out"
  untouched
}

echo "==> 1. version order"
ORDER="$("$PROBE" --compare "$BUILD" "$NEXT")"
[ "$ORDER" = "$BUILD < $NEXT" ] && check ok "Sparkle: $ORDER" || check no "Sparkle: $ORDER"

echo "==> 2. a signature for other bytes"
refused appcast-tampered.xml "a signature for other bytes"

echo "==> 3. the right certificate, another EdDSA key"
refused appcast-rotated.xml "an update signed \"Kleoth Self-Signed\" with another EdDSA key"

echo "==> 4. found, downloaded, validated, installed over the copy (it is not running: no prompt)"
settle
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
