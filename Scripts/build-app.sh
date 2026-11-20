#!/bin/bash
# Assembles Size.app from the SwiftPM build.
#
# Signing: if a code-signing identity named "Size Dev" exists, it is used, which
# keeps the Accessibility permission across rebuilds. Otherwise the bundle is
# signed ad-hoc, which works but makes macOS forget the permission every time
# the binary changes. Run Scripts/make-signing-identity.sh once to get the
# stable identity.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"
APP="$ROOT/build/Size.app"

echo "Building ($CONFIGURATION)…"
swift build -c "$CONFIGURATION" --package-path "$ROOT" --product Size

BINARY="$ROOT/.build/$CONFIGURATION/Size"
if [ ! -f "$BINARY" ]; then
    echo "Build produced no binary at $BINARY" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Size"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# The icon must be inside the bundle for Finder and the Dock to use it.
if [ -f "$ROOT/Resources/Size.icns" ]; then
    cp "$ROOT/Resources/Size.icns" "$APP/Contents/Resources/Size.icns"
else
    echo "warning: Resources/Size.icns is missing; run Scripts/make-icon.sh" >&2
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

IDENTITY="${SIZE_SIGN_IDENTITY:-}"

# Accessibility permission is keyed to the code signature: an ad-hoc build gets a
# new identity on every rebuild, which silently drops the grant the user already
# gave. Prefer a stable identity so the permission survives rebuilds.
if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q '"Size Dev"'; then
    IDENTITY="Size Dev"
fi

# Never fall back to an arbitrary "Apple Development" certificate.
# Those rotate, expire and get revoked; a revoked signature makes Gatekeeper
# treat the app as malware and move it to the Trash — strictly worse than
# ad-hoc signing, which at least launches. A local self-signed "Size Dev"
# identity (see Scripts/make-signing-identity.sh) is the supported option.
if [ -n "$IDENTITY" ]; then
    # No --options runtime: hardened runtime without a provisioning profile makes
    # launchd refuse to spawn the app (RBSRequestErrorDomain Code=5, POSIX 163).
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with identity: $IDENTITY"
    echo "Accessibility permission stays granted across rebuilds."
else
    codesign --force --sign - "$APP"
    echo "Signed ad-hoc (Accessibility permission will reset on every rebuild)."
    echo "Run Scripts/make-signing-identity.sh once for a stable identity."
fi

# Fail loudly if the resulting signature is not acceptable to the system, so a
# bad identity can never reach the user as a "malware blocked" dialog.
if ! codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/  /'; then
    echo "Signature verification failed." >&2
    exit 1
fi

if ! spctl --assess --type execute "$APP" 2>&1; then
    echo >&2
    echo "WARNING: Gatekeeper rejects this build's signature (see above)." >&2
    echo "If it says CSSMERR_TP_CERT_REVOKED, the signing certificate was" >&2
    echo "revoked — run Scripts/make-signing-identity.sh and rebuild." >&2
fi
echo
echo "Built: $APP"
echo "Launch: open \"$APP\""
