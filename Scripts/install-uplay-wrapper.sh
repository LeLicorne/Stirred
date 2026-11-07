#!/bin/sh
# Same Chromium workaround as for Steam, applied to Ubisoft Connect's UplayWebCore.exe.
# Builds the wrapper with REAL_EXE=UplayWebCore_real.exe and (re)deploys it. Requires mingw-w64.
set -eu
ROOT="${STIRRED_ROOT:-$HOME/Library/Application Support/Stirred}"
PREFIX="${STIRRED_PREFIX:-$ROOT/prefixes/steam}"
DIR="$PREFIX/drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/uplaywebcore_wrapper.exe"
CC="${CC:-/opt/homebrew/bin/x86_64-w64-mingw32-gcc}"
[ -x "$CC" ] || { echo "mingw-w64 missing: brew install mingw-w64" >&2; exit 1; }
[ -f "$DIR/UplayWebCore.exe" ] || { echo "Ubisoft Connect not installed yet in the prefix" >&2; exit 1; }
"$CC" -O2 -municode -mwindows -static -DREAL_EXE='L"UplayWebCore_real.exe"' -o "$OUT" "$HERE/Wrapper/steamwebhelper_wrapper.c"
target="$DIR/UplayWebCore.exe"; real="$DIR/UplayWebCore_real.exe"
if [ "$(stat -f%z "$target")" -lt 500000 ]; then   # already a wrapper (size, never hash)
    [ -f "$real" ] && [ "$(stat -f%z "$real")" -gt 500000 ] || { echo "ERROR: $real missing or not the original" >&2; exit 1; }
    cp -f "$OUT" "$target"; echo "refreshed wrapper"
else
    cp -f "$target" "$real"; cp -f "$OUT" "$target"; echo "wrapped UplayWebCore.exe"
fi
