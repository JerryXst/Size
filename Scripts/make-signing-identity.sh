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

# Pin the system build (LibreSSL 3.3.6). Homebrew's OpenSSL 3.x writes the
# PKCS#12 with PBES2/AES-256-CBC; SecKeychainItemImport cannot read that and
# fails with "MAC verification failed during PKCS12 import (wrong password?)",
# so the certificate never gets installed and builds silently stay ad-hoc
# signed (Accessibility grant resets on every rebuild).
#
# Do NOT "fix" that with -certpbe/-keypbe/-macalg DES-CBC: OpenSSL 3.x has no
# legacy provider by default, rejects those ciphers and emits no .p12 at all,
# which is worse — the import then fails with "Unknown format in import".
OPENSSL=/usr/bin/openssl
if [ ! -x "$OPENSSL" ]; then
    echo "No /usr/bin/openssl; falling back to whatever is on PATH." >&2
    OPENSSL=openssl
fi

echo "Generating certificate \"$IDENTITY_NAME\"…"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$IDENTITY_NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null

# Force the legacy PKCS#12 algorithms. Without these the key/bag ciphers
# default to AES-256-CBC (PBES2), which SecKeychainItemImport cannot read;
# it then fails with "MAC verification failed during PKCS12 import
# (wrong password?)" — the password is fine, the cipher is not.
"$OPENSSL" pkcs12 -export \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout pass:size -name "$IDENTITY_NAME" \
    -certpbe DES-CBC -keypbe DES-CBC -macalg sha1 >/dev/null

echo "Importing into the login keychain…"
# Delete stale copies first: two certificates with the same name make
# `codesign --sign "Size Dev"` fail with "ambiguous (matches ... and ...)",
# which is how a half-installed identity hides itself.
while security find-certificate -c "$IDENTITY_NAME" >/dev/null 2>&1; do
    hash="$(security find-certificate -a -c "$IDENTITY_NAME" -Z 2>/dev/null \
        | awk '/SHA-256:/{print $NF; exit}')"
    [ -n "$hash" ] || break
    security delete-certificate -Z "$hash" "$KEYCHAIN" >/dev/null 2>&1 || break
done

# Fail loudly here: a swallowed error here previously left the app ad-hoc
# signed while the script still printed "Done".
if ! security import "$WORK/identity.p12" -k "$KEYCHAIN" -P size -T /usr/bin/codesign; then
    echo "Import failed — the .p12 was not created or cannot be read." >&2
    echo "Check the openssl version: /usr/bin/openssl version -a" >&2
    exit 1
fi

echo "Trusting the certificate for code signing…"
# -d would require sudo; a user-level trust setting is enough for codesign.
security add-trusted-cert -r trustRoot -k "$KEYCHAIN" "$WORK/cert.pem" || {
    echo "Could not set trust automatically. Open Keychain Access, find" >&2
    echo "\"$IDENTITY_NAME\", open it, expand Trust and set Code Signing to" >&2
    echo "Always Trust." >&2
}

echo
security find-identity -v -p codesigning | grep "$IDENTITY_NAME" || {
    echo "Warning: import said OK but codesign still cannot see the identity." >&2
    echo "Reboot, or import $WORK/identity.p12 by double-clicking it," >&2
    echo "then set Trust to Always Trust, and re-run: bash Scripts/verify.sh" >&2
}
echo "Done. Future builds will be signed with this identity."
