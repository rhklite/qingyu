#!/usr/bin/env bash
# Create a STABLE self-signed code-signing identity for Qingyu.
#
# Why: ad-hoc signatures (`codesign -s -`) change their cdhash on every rebuild,
# so macOS treats each build as a brand-new app and forgets every TCC permission
# (Accessibility, Input Monitoring, Microphone) you granted. Signing with a fixed
# self-signed cert keeps the code identity constant across rebuilds, so you grant
# each permission ONCE and it sticks.
#
# The identity lives in a dedicated keychain with a known password (local-dev only,
# not a secret worth protecting) so the build can sign non-interactively.
set -euo pipefail

IDENTITY="Qingyu Local Dev"
KC="$HOME/Library/Keychains/qingyu-signing.keychain-db"
KC_PW="qingyu-local-signing"
CERT_PW="qingyu"

OPENSSL="/opt/homebrew/opt/openssl@3/bin/openssl"
[ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl)"

# Already set up? Nothing to do. (Check the keychain WITHOUT -v: a self-signed cert is
# untrusted, so `-v` hides it and we'd create a duplicate every run → codesign then
# fails with "ambiguous (matches … and …)".)
if security find-identity "$KC" 2>/dev/null | grep -q "$IDENTITY"; then
    echo "Signing identity '$IDENTITY' already present."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. Dedicated keychain (idempotent create), unlocked, no auto-lock.
security create-keychain -p "$KC_PW" "$KC" 2>/dev/null || true
security unlock-keychain -p "$KC_PW" "$KC"
security set-keychain-settings "$KC"          # disable timeout/lock-on-sleep

# Add it to the user search list without dropping the existing keychains.
EXISTING="$(security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/"//g')"
# shellcheck disable=SC2086
security list-keychains -d user -s "$KC" $EXISTING

# 2. Self-signed cert with the codeSigning extended key usage.
"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$IDENTITY" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
"$OPENSSL" pkcs12 -export -legacy \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/id.p12" -passout "pass:$CERT_PW" -name "$IDENTITY" >/dev/null 2>&1

# 3. Import key+cert; allow /usr/bin/codesign to use the private key with no UI prompt.
security import "$WORK/id.p12" -k "$KC" -P "$CERT_PW" -T /usr/bin/codesign -A
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PW" "$KC" >/dev/null 2>&1

echo "--- codesigning identities ---"
security find-identity -v -p codesigning
echo "Done. Build with: bash scripts/build.sh"
