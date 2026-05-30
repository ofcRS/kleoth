#!/usr/bin/env bash
# Create a STABLE self-signed code-signing identity for Kleoth.
#
# Why: macOS TCC ties permission grants (microphone, system-audio) to the app's
# code signature. Ad-hoc signing produces a new identity on every rebuild, so
# grants don't persist. A stable self-signed certificate fixes that — grant
# once, and it survives rebuilds.
#
# Idempotent: re-running reuses the existing identity. Non-interactive: it uses a
# dedicated keychain whose password it controls, so codesign never prompts.
set -euo pipefail

IDENTITY="Kleoth Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/kleoth-codesign.keychain-db"
KC_PASS="kleoth-codesign"   # local-only password for the signing keychain
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
    echo "Identity '$IDENTITY' already present in $KEYCHAIN"
    exit 0
fi

echo "==> generating self-signed code-signing certificate"
cat > "$WORK/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Kleoth Self-Signed
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -config "$WORK/openssl.cnf" >/dev/null 2>&1
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$IDENTITY" -out "$WORK/identity.p12" -passout pass:"$KC_PASS" >/dev/null 2>&1

echo "==> importing into dedicated keychain $KEYCHAIN"
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$KC_PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"            # no auto-lock timeout
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$KC_PASS" -T /usr/bin/codesign
# Allow codesign to use the key without a GUI prompt.
security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null 2>&1
# Make sure the keychain is on the user search list (so codesign finds it).
security list-keychains -d user -s "$KEYCHAIN" "$HOME/Library/Keychains/login.keychain-db" >/dev/null

echo "==> done. Identity ready (untrusted self-signed is expected — codesign only needs the key):"
security find-identity "$KEYCHAIN" | grep "$IDENTITY"
