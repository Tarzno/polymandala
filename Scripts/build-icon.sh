#!/bin/zsh
# Regenerates Support/AppIcon.icns from the programmatic master icon.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
MASTER="$TMP/AppIcon-1024.png"
swift Tools/icongen.swift "$MASTER"

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for entry in 16 32 128 256 512; do
    sips -z $entry $entry "$MASTER" --out "$ICONSET/icon_${entry}x${entry}.png" >/dev/null
    double=$((entry * 2))
    sips -z $double $double "$MASTER" --out "$ICONSET/icon_${entry}x${entry}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Support/AppIcon.icns
echo "Wrote Support/AppIcon.icns"
