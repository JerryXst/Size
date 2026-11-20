#!/bin/bash
# Builds Resources/Size.icns from a source image.
#
# Usage: Scripts/make-icon.sh <source-image.png>
#
# The source image is normalised by make-icon.swift (backdrop turned into
# transparency, artwork placed on Apple's icon grid) and then sliced into every
# size macOS asks for.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-}"
OUT="$ROOT/Resources/Size.icns"

if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
    echo "usage: Scripts/make-icon.sh <source-image.png>" >&2
    exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MASTER="$WORK/master-1024.png"
echo "Normalising source…"
swift "$ROOT/Scripts/make-icon.swift" "$SRC" "$MASTER"

ICONSET="$WORK/Size.iconset"
mkdir -p "$ICONSET"

# sips takes a square size; @2x entries are what Retina picks up.
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$MASTER" \
        --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$MASTER" \
        --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

# iconutil refuses an incomplete set silently, so state what was produced.
echo "Sliced sizes: $(ls "$ICONSET" | wc -l | tr -d ' ')"
iconutil -c icns "$ICONSET" -o "$OUT"

echo "Wrote $OUT ($(du -h "$OUT" | cut -f1))"
