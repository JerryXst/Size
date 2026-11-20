#!/bin/bash
# Creates a self-signed code-signing certificate called "Size Dev" in the login
# keychain.
#
# Why bother: macOS records the Accessibility grant against the app's code
# signature. An ad-hoc signature is a hash of the binary, so every rebuild looks
# like a brand new app and the permission silently resets. Signing with a stable
# certificate makes the permission survive rebuilds.
#
# Run once. macOS may ask for your login password and to allow codesign to use
# the key — that is expected.
set -euo pipefail

IDENTITY_NAME="${1:-Size Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY_NAME\""; then
    echo "Identity \"$IDENTITY_NAME\" already exists."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Generating certificate \"$IDENTITY_NAME\"…"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$IDENTITY_NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

openssl pkcs12 -export \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout pass:size -name "$IDENTITY_NAME" 2>/dev/null

echo "Importing into the login keychain…"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P size -T /usr/bin/codesign

echo "Trusting the certificate for code signing…"
# -d would require sudo; a user-level trust setting is enough for codesign.
security add-trusted-cert -r trustRoot -k "$KEYCHAIN" "$WORK/cert.pem" || {
    echo "Could not set trust automatically. Open Keychain Access, find" >&2
    echo "\"$IDENTITY_NAME\", open it, expand Trust and set Code Signing to" >&2
    echo "Always Trust." >&2
}

echo
security find-identity -v -p codesigning | grep "$IDENTITY_NAME" || true
echo "Done. Future builds will be signed with this identity."
