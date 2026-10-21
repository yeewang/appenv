#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build.sh
APP="$PWD/dist/AppEnv.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCH="$(lipo -archs "$APP/Contents/MacOS/AppEnv" | tr ' ' '-')"
NAME="AppEnv-${VERSION}-macOS-${ARCH}"
OUT="$PWD/dist/releases"
mkdir -p "$OUT"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/appenv-release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/AppEnv.app"
mkdir -p "$STAGE/bin"
cp dist/bin/appenv "$STAGE/bin/appenv"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/README.txt" <<EOF
AppEnv $VERSION for macOS 14 or newer ($ARCH)

Drag AppEnv.app into Applications. The optional command-line tool is in bin.
Each environment has separate supported app profiles. This is not a security sandbox.

This local release is not notarized. Default builds use an ad-hoc signature.
EOF
ditto -c -k --sequesterRsrc --keepParent "$STAGE/AppEnv.app" "$OUT/$NAME.zip"
hdiutil create -ov -volname "AppEnv $VERSION" -srcfolder "$STAGE" -format UDZO "$OUT/$NAME.dmg"
hdiutil verify "$OUT/$NAME.dmg"
ditto -x -k "$OUT/$NAME.zip" "$STAGE/verify"
codesign --verify --strict "$STAGE/verify/AppEnv.app"
codesign --verify --strict "$STAGE/bin/appenv"
cd "$OUT"
shasum -a 256 "$NAME.dmg" "$NAME.zip" > "$NAME.sha256"
printf 'Release artifacts: %s\n' "$OUT"
