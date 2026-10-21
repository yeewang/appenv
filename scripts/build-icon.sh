#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ICON_WORK="$(mktemp -d "${TMPDIR:-/tmp}/appenv-icon.XXXXXX")"
trap 'rm -rf "$ICON_WORK"' EXIT
ICONSET="$ICON_WORK/AppIcon.iconset"
mkdir -p "$ICONSET" dist
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o dist/AppIcon.icns
