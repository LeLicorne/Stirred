#!/bin/sh
# Builds the app and packs it into build/Stirred.dmg (ad-hoc signed: opening it the first time needs
# System Settings > Privacy & Security > "Open Anyway", see README).
set -eu
cd "$(dirname "$0")/.."
Scripts/build-app.sh "${1:-release}"
rm -f build/Stirred.dmg
hdiutil create -quiet -volname Stirred -srcfolder build/Stirred.app -ov -format UDZO build/Stirred.dmg
echo "built build/Stirred.dmg"
