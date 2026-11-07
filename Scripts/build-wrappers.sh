#!/bin/sh
# Rebuilds Resources/wrappers/steamwebhelper_wrapper.exe from Wrapper/steamwebhelper_wrapper.c.
# Only needed when the C source changes (the compiled file is committed). Requires: brew install mingw-w64
set -eu
cd "$(dirname "$0")/.."
CC="${CC:-/opt/homebrew/bin/x86_64-w64-mingw32-gcc}"
[ -x "$CC" ] || { echo "mingw-w64 missing: brew install mingw-w64" >&2; exit 1; }
mkdir -p Resources/wrappers
"$CC" -O2 -municode -mwindows -static -o Resources/wrappers/steamwebhelper_wrapper.exe Wrapper/steamwebhelper_wrapper.c
echo "built Resources/wrappers/steamwebhelper_wrapper.exe"
