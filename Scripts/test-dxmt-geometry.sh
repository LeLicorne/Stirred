#!/bin/sh
# Checks where the DXMT engine really draws: a test program fills its window with magenta, a screenshot is taken and the
# magenta rectangle is measured against the client area Windows reports. Catches a hidden, misplaced or unresized Metal view.
# Needs: the DXMT engine, mingw-w64, Screen Recording permission for the terminal. Windows pop up for about a minute.
# Usage: Scripts/test-dxmt-geometry.sh [stirred-root]
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${1:-$HOME/Library/Application Support/Stirred}"
WINE="$ROOT/engines/stirred-wine-11.21-dxmt/Wine Staging.app/Contents/Resources/wine/bin/wine"
[ -x "$WINE" ] || { echo "DXMT engine not found in $ROOT/engines"; exit 1; }
WORK="$(mktemp -d)"; cd "$WORK"
x86_64-w64-mingw32-gcc -O2 -mwindows -o d3d11_geometry.exe "$HERE/Tests/Integration/d3d11_geometry.c" -ld3d11 -ldxgi -luuid
cp "$HERE/Tests/Integration/magenta_box.swift" .
run() { # mode, expected box after the change
  rm -f d3d11_geometry.log
  (WINEPREFIX="$ROOT/prefixes/steam" WINEDEBUG=-all WINEMSYNC=1 arch -x86_64 "$WINE" ./d3d11_geometry.exe "$1" 12 >/dev/null 2>&1 &)
  sleep 8; screencapture -x "shot-$1.png"
  printf '%-7s %s\n        expected: %s\n' "$1" "$(swift magenta_box.swift "shot-$1.png")" "$2"
  sleep 5
}
run window "origin=(200,150) size=800x500"
run move   "origin=(300,200) size=800x500"
run grow   "origin=(300,200) size=1000x600"
run resize "origin=(300,200) size=1000x600"
run full   "the whole screen below the menu bar"
echo "screenshots kept in $WORK"
