#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$PWD/dist/AppEnv.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$PWD/dist/bin"
bash scripts/build-icon.sh
cp dist/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$BIN_DIR/AppEnvDesktop" "$APP_DIR/Contents/MacOS/AppEnvDesktop"
# Remove the legacy GUI filename before installing the CLI: these names collide
# on the default case-insensitive macOS filesystem.
rm -f "$APP_DIR/Contents/MacOS/AppEnv"
cp "$BIN_DIR/appenv" "$APP_DIR/Contents/MacOS/appenv"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AppEnvDesktop</string>
<key>CFBundleIdentifier</key><string>im.bots.appenv</string>
<key>CFBundleName</key><string>AppEnv</string>
<key>CFBundleDisplayName</key><string>AppEnv</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Local development signature. Set SIGN_IDENTITY for a Developer ID release.
codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$APP_DIR/Contents/MacOS/appenv"
codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$APP_DIR"
cp "$APP_DIR/Contents/MacOS/appenv" "$PWD/dist/bin/appenv"
codesign --verify --strict "$APP_DIR/Contents/MacOS/appenv"
codesign --verify --strict "$APP_DIR"
printf 'Built: %s\nCLI: %s\n' "$APP_DIR" "$PWD/dist/bin/appenv"
