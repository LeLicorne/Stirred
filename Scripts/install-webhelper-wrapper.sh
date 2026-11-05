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

for dir in "$CEF"/cef.win64; do
    [ -d "$dir" ] || continue
    target="$dir/steamwebhelper.exe"; real="$dir/steamwebhelper_real.exe"
    [ -f "$target" ] || continue
    # Classify by SIZE, never by hash: a rebuilt wrapper has a different hash but is still tiny.
    # (Valve's helper is ~7.5 MB; our wrapper is ~150 KB.)
    size=$(stat -f%z "$target")
    if [ "$size" -lt 500000 ]; then
        # Already a wrapper: refresh it, never touch the real helper.
        [ -f "$real" ] && [ "$(stat -f%z "$real")" -gt 500000 ] \
            || { echo "ERROR: $real is missing or is not Valve's helper. Let Steam restore it (launch once WITHOUT -noverifyfiles), then rerun." >&2; exit 1; }
        cp -f "$OUT" "$target"
        echo "refreshed wrapper: $dir"
    else
        cp -f "$target" "$real"
        cp -f "$OUT" "$target"
        echo "wrapped: $dir"
    fi
done
