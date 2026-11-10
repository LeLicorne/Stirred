# DXMT experiment (Direct3D 11 -> Metal)

Why: DXVK on MoltenVK cannot draw some Unreal/Unity 3D scenes (no geometry shaders, no typed storage image formats): RV There Yet?
and Orcs Must Die 3 show menus but a black 3D scene. DXMT talks to Metal directly and supports geometry shaders.

What was needed (2026-11-08):
- DXMT v0.80 finds Wine's Metal hooks with `dlsym(RTLD_DEFAULT, "macdrv_functions")` (a table of function pointers) and reads a
  window-data layout `{hwnd, cocoa_window, cocoa_view, client_cocoa_view}`. Upstream Wine hides all `macdrv_*` symbols and has
  another layout, so the Gcenx build fails with "Failed to create metal view".
- `Patches/dxmt/window_dxmt.c.inc` adds to Wine's `winemac.drv` an exported `macdrv_functions` table and wrappers that present the
  window data in DXMT's layout (the view is created on demand), and `Scripts/build-dxmt-engine.sh` exports the five Metal entry
  points, rebuilds only `winemac.so` (Wine 11.21 + Staging 11.21, x86_64 under Rosetta, about 15 min at -j4) and overlays DXMT.
- Result: the D3D11 smoke test (`Tests/Integration/d3d11_clear.c`) creates a device and swap chain and presents 360 frames with no
  error; RV There Yet? reaches its main menu with DXMT and no MoltenVK error in the log (DXVK removed from its folder, recipe
  `"graphics": "dxmt"`).
- Confirmed by a human (2026-11-08): the 3D scene of RV There Yet? is drawn with DXMT and a solo run of about 6 minutes in the map
  ended cleanly. Not working: multiplayer (Epic Online Services: session creation times out). Untested: other games, long sessions.

## How Stirred uses it (optional engine)

- The engine is `engines/stirred-wine-<version>-dxmt` (a copy of the normal engine with the rebuilt `winemac.so` and DXMT). It is never
  chosen by default and is invisible to engine updates.
- A game uses it when its recipe or personal setting says `"graphics": "dxmt"`. Without the engine installed, Stirred falls back to DXVK
  and says so in the warnings, so shared recipes never break.
- Steam and its games share one Wine, so when a DXMT game starts and Steam runs under the other engine, Stirred closes Steam
  and restarts it with the right one (`engines/steam-engine.txt` remembers which, and is removed when Steam stops).
- Automatic: an Unreal Engine game (a `*-Win64-Shipping.exe` under `Binaries/Win64`) whose recipe sets no graphics layer starts with `-dx11` and
  DXMT when the engine is installed (DXVK + `-dx11` otherwise). A recipe or personal setting always wins.
- On first use Stirred copies `winemetal.dll` into the prefix's system folders and removes DXVK's DLLs, `dxvk.conf` and registry override
  for that game; switching back to DXVK reinstalls them.
- Install: `Scripts/build-dxmt-engine.sh` (about 15 minutes of compiling, needs Homebrew bison pkgconf autoconf mingw-w64 and gh).
  Remove: delete the `-dxmt` folder in `engines/`.

Manual test without Stirred's app (separate data folder, optional):

    STIRRED_ROOT=<copy of your data> .build/debug/stirredctl run "rv there" --hud --keep-steam

Wine and DXMT are LGPL: the patch and script are the corresponding source for the rebuilt `winemac.so`.

## Cursor stays hidden while a game controls the mouse

`Patches/dxmt/cursor-stay-hidden.patch` (applied by the build script): Wine's Mac driver brought the cursor back whenever no Wine window was
under the pointer (while a game recentres the mouse, or when a notification or the overlay passes). Now a cursor the game hid stays hidden while
the app is active; it returns when the game shows it or when you switch to another app. Only the `-dxmt` engine has it.
