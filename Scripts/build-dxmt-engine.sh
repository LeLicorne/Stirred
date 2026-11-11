#!/bin/sh
# Builds an experimental engine that can run DXMT (Direct3D 11 -> Metal): a copy of the installed engine whose winemac.so is
# rebuilt from Wine 11.21 + Wine Staging 11.21 with the entry points DXMT needs exported (see Patches/dxmt/window_dxmt.c.inc),
# plus DXMT v0.80 itself. Takes about 15 minutes of compiling; nothing in your real Stirred data is touched.
# Needs: Xcode command line tools, Homebrew packages bison pkgconf autoconf mingw-w64, Rosetta 2, gh (GitHub CLI).
# Usage: Scripts/build-dxmt-engine.sh [build-dir] [stirred-root]
#   build-dir     sources and compiled objects (default ~/Library/Application Support/Stirred-dxmt-build)
#   stirred-root  Stirred's data folder (default ~/Library/Application Support/Stirred); the result is
#                 <stirred-root>/engines/stirred-wine-11.21-dxmt, an OPTIONAL engine: Stirred only uses it for games set to DXMT.
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${1:-$HOME/Library/Application Support/Stirred-dxmt-build}"
ROOT="${2:-$HOME/Library/Application Support/Stirred}"
SRC="$WORK/build"; mkdir -p "$SRC" "$ROOT/engines"
export PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/bin:$PATH" PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig
cd "$SRC"
[ -f wine-11.21.tar.xz ] || curl -fL -o wine-11.21.tar.xz https://dl.winehq.org/wine/source/11.x/wine-11.21.tar.xz
[ -f staging.tar.gz ] || curl -fL -o staging.tar.gz https://github.com/wine-staging/wine-staging/archive/refs/tags/v11.21.tar.gz
if [ ! -d src/wine-11.21 ]; then
  mkdir -p src; tar -xf wine-11.21.tar.xz -C src; tar -xzf staging.tar.gz -C src
  (cd src/wine-11.21 && python3 ../wine-staging-11.21/staging/patchinstall.py DESTDIR=. --all)
  D=src/wine-11.21/dlls/winemac.drv
  python3 - "$D" <<'PY'
import re, sys
d = sys.argv[1]
p = d + '/macdrv_cocoa.h'; s = open(p).read()
for fn in ['macdrv_create_metal_device', 'macdrv_release_metal_device', 'macdrv_view_create_metal_view', 'macdrv_view_get_metal_layer', 'macdrv_view_release_metal_view']:
    s = re.sub(r'^(extern [^\n]*\b' + fn + r'\()', lambda m: '__attribute__((visibility("default"))) ' + m.group(1), s, count=1, flags=re.M)
open(p, 'w').write(s)
PY
  cat "$HERE/Patches/dxmt/window_dxmt.c.inc" >> "$D/window.c"
  (cd src/wine-11.21 && patch -p1 < "$HERE/Patches/dxmt/client-view-frame.patch" && patch -p1 < "$HERE/Patches/dxmt/cursor-stay-hidden.patch")
fi
mkdir -p obj && cd obj
[ -f Makefile ] || nice arch -x86_64 /bin/zsh -c '../src/wine-11.21/configure --enable-archs=i386,x86_64 --disable-tests --without-x --without-freetype --with-mingw CC="clang -arch x86_64" CXX="clang++ -arch x86_64"' > configure.log 2>&1
nice arch -x86_64 /bin/zsh -c 'make -j4 dlls/winemac.drv/winemac.so' > make.log 2>&1
cd "$SRC"
mkdir -p dxmt
[ -f dxmt/dxmt-v0.80-builtin.tar.gz ] || gh release download v0.80 -R 3Shain/dxmt -p 'dxmt-v0.80-builtin.tar.gz' -D dxmt
[ -d dxmt/x ] || { mkdir dxmt/x; tar -xzf dxmt/dxmt-v0.80-builtin.tar.gz -C dxmt/x; }
ENGINE="$ROOT/engines/stirred-wine-11.21-dxmt"
[ -d "$ENGINE" ] || cp -cR "$ROOT/engines/stirred-wine-11.21" "$ENGINE"
LIB="$ENGINE/Wine Staging.app/Contents/Resources/wine/lib/wine"; X="$SRC/dxmt/x/v0.80"
cp obj/dlls/winemac.drv/winemac.so "$LIB/x86_64-unix/winemac.so"
cp "$X/x86_64-unix/winemetal.so" "$LIB/x86_64-unix/"
for f in d3d10core d3d11 dxgi winemetal; do cp "$X/x86_64-windows/$f.dll" "$LIB/x86_64-windows/"; cp "$X/i386-windows/$f.dll" "$LIB/i386-windows/"; done
cp "$X/x86_64-windows/nvapi64.dll" "$X/x86_64-windows/nvngx.dll" "$LIB/x86_64-windows/"
echo "engine ready: $ENGINE"
echo "Stirred copies winemetal.dll into the prefix by itself the first time a DXMT game starts."
