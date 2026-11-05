#!/bin/sh
# Assembles a Stirred engine: upstream Wine build + DXMT overlaid into it.
# Reproduces what was done by hand in phase 0. Downloads only from the projects' GitHub releases.
# Requires: gh (authenticated), tar, xz.
set -eu

WINE_TAG="${WINE_TAG:-11.21}"
WINE_ASSET="wine-staging-${WINE_TAG}-osx64.tar.xz"
DXMT_TAG="${DXMT_TAG:-v0.80}"
DXMT_ASSET="dxmt-${DXMT_TAG}-builtin.tar.gz"

ROOT="${STIRRED_ROOT:-$HOME/Library/Application Support/Stirred}"
DL="$ROOT/downloads"; ENG="$ROOT/engines"
NAME="stirred-${WINE_TAG}-dxmt${DXMT_TAG#v}"

mkdir -p "$DL" "$ENG"
cd "$DL"
gh release download "$WINE_TAG" -R Gcenx/macOS_Wine_builds -p "$WINE_ASSET" --skip-existing
gh release download "$DXMT_TAG" -R 3Shain/dxmt -p "$DXMT_ASSET" --skip-existing
shasum -a 256 "$WINE_ASSET" "$DXMT_ASSET"   # record these in THIRD_PARTY_LICENSES.md when you bump versions

rm -rf "$ENG/_wine" "$ENG/_dxmt" "$ENG/$NAME"
mkdir -p "$ENG/_wine" "$ENG/_dxmt"
tar -xf "$WINE_ASSET" -C "$ENG/_wine"
tar -xzf "$DXMT_ASSET" -C "$ENG/_dxmt"
xattr -dr com.apple.quarantine "$ENG/_wine" "$ENG/_dxmt" 2>/dev/null || true

# APFS clone: instant, no extra disk space.
cp -c -R "$ENG/_wine" "$ENG/$NAME"
APP=$(ls -d "$ENG/$NAME"/*.app | head -1)
LIB="$APP/Contents/Resources/wine/lib/wine"
SRC="$ENG/_dxmt/$DXMT_TAG"
cp "$SRC/x86_64-unix/winemetal.so" "$LIB/x86_64-unix/"
cp "$SRC/x86_64-windows/"*.dll "$LIB/x86_64-windows/"
cp "$SRC/i386-windows/"*.dll "$LIB/i386-windows/"
rm -rf "$ENG/_wine" "$ENG/_dxmt"
echo "engine ready: $ENG/$NAME"
