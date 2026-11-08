#!/bin/sh
# Builds build/Stirred.app (debug build, ad-hoc signed: no Apple developer account needed).
# Usage: Scripts/build-app.sh [release]
set -eu
cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"
swift build -c "$CONFIG" -j 4 --product StirredApp
BIN="$(swift build -c "$CONFIG" --show-bin-path)/StirredApp"
APP="build/Stirred.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/StirredApp"
cp -R recipes "$APP/Contents/Resources/recipes"
cp -R Resources/wrappers "$APP/Contents/Resources/wrappers"
cp Resources/engines.json "$APP/Contents/Resources/engines.json"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>StirredApp</string>
  <key>CFBundleIdentifier</key><string>dev.stirred.app</string>
  <key>CFBundleName</key><string>Stirred</string>
  <key>CFBundleDisplayName</key><string>Stirred</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc signing failed"
echo "built: $APP   (open with: open $APP)"
