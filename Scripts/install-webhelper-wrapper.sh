#!/bin/sh
# Builds the steamwebhelper wrapper and (re)deploys it into every Steam cef.win* directory.
# Safe to run repeatedly; run it before each Steam launch because Steam may restore the original helper.
# Requires: mingw-w64 (brew install mingw-w64).
set -eu

ROOT="${STIRRED_ROOT:-$HOME/Library/Application Support/Stirred}"
PREFIX="${STIRRED_PREFIX:-$ROOT/prefixes/steam}"
CEF="$PREFIX/drive_c/Program Files (x86)/Steam/bin/cef"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/steamwebhelper_wrapper.exe"
CC="${CC:-/opt/homebrew/bin/x86_64-w64-mingw32-gcc}"

[ -x "$CC" ] || { echo "mingw-w64 missing: brew install mingw-w64" >&2; exit 1; }
"$CC" -O2 -municode -mwindows -static -o "$OUT" "$HERE/Wrapper/steamwebhelper_wrapper.c"
WRAP_SUM=$(shasum -a 256 "$OUT" | cut -d' ' -f1)

for dir in "$CEF"/cef.win*; do
    [ -d "$dir" ] || continue
    target="$dir/steamwebhelper.exe"; real="$dir/steamwebhelper_real.exe"
    [ -f "$target" ] || continue
    if [ "$(shasum -a 256 "$target" | cut -d' ' -f1)" = "$WRAP_SUM" ]; then
        echo "ok (already wrapped): $dir"; continue
    fi
    # Anything that is not our wrapper is Valve's original: keep it as the "real" helper.
    cp -f "$target" "$real"
    cp -f "$OUT" "$target"
    echo "wrapped: $dir"
done
