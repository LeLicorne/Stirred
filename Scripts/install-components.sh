#!/bin/sh
# Installs graphics components (not part of the Wine engine) under $ROOT/components.
# DXVK-macOS (Gcenx, zlib license) is a DXVK 1.10.3 fork that works on MoltenVK (no geometry shaders on Metal).
# Official DXVK >= 2.x refuses to start on macOS for that reason; DXMT needs a Wine with exported macdrv symbols.
set -eu
ROOT="${STIRRED_ROOT:-$HOME/Library/Application Support/Stirred}"
TAG="v1.10.3-20230507"; ASSET="dxvk-macOS-async-v1.10.3-20230507.tar.gz"
mkdir -p "$ROOT/downloads" "$ROOT/components"; cd "$ROOT/downloads"
gh release download "$TAG" -R Gcenx/DXVK-macOS -p "$ASSET" --skip-existing
shasum -a 256 "$ASSET"   # f67d99d0a8eeedd7d406b283a3df9f939b5965acb00efcb33d0c6235c195a516 on 2026-11-07
rm -rf "$ROOT/components/_tmp" "$ROOT/components/dxvk-macos-1.10.3"; mkdir -p "$ROOT/components/_tmp"
tar -xzf "$ASSET" -C "$ROOT/components/_tmp"
mv "$ROOT/components/_tmp/dxvk-macOS-async-v1.10.3-20230507" "$ROOT/components/dxvk-macos-1.10.3"
rm -rf "$ROOT/components/_tmp"; echo "installed: $ROOT/components/dxvk-macos-1.10.3"
