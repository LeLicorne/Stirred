#!/bin/sh
# Lets Warframe's own launcher (Tools/Launcher.exe, Chromium) get past its hardware check and update the game under Wine.
# Findings (2026-11-07): the launcher needs a working D3D11/DXGI for its spec check (DXVK provides it) while its Chromium UI
# must NOT get a working Direct3D shader compiler, otherwise the page stays blank/hangs: d3dcompiler_* are disabled for Launcher.exe only.
# Then run it once:  stirredctl run warframe --via-steam   (the launcher updates; its window may stay white), and play with the direct launch.
set -eu
ROOT="${STIRRED_ROOT:-$HOME/Library/Application Support/Stirred}"
PREFIX="$ROOT/prefixes/steam"
TOOLS="$PREFIX/drive_c/Program Files (x86)/Steam/steamapps/common/Warframe/Tools"
WINE="$(ls -d "$ROOT"/engines/stirred-*/*.app | tail -1)/Contents/Resources/wine/bin/wine"
cp "$ROOT/components/dxvk-macos-1.10.3/x64/"d3d11.dll "$ROOT/components/dxvk-macos-1.10.3/x64/"dxgi.dll "$ROOT/components/dxvk-macos-1.10.3/x64/"d3d10core.dll "$TOOLS/"
export WINEPREFIX="$PREFIX" WINEDEBUG=-all
K='HKCU\Software\Wine\AppDefaults\Launcher.exe\DllOverrides'
for d in d3d11 dxgi d3d10core; do "$WINE" reg add "$K" /v $d /d native,builtin /f >/dev/null 2>&1; done
for d in d3dcompiler_47 d3dcompiler_46 d3dcompiler_43; do "$WINE" reg add "$K" /v $d /d "" /f >/dev/null 2>&1; done
echo "Warframe launcher configured."
