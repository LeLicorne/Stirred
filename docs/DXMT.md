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
- NOT verified: whether the 3D scene is now drawn. Metal windows cannot be captured from here (the capture is blank), so this needs
  a human look. Also untested: stability over time, performance, multiplayer, other games.

Try it (the test setup lives in `~/Library/Application Support/Stirred-dxmt-test`, a copy of your Windows environment made with
APFS cloning, so your real Steam and games are untouched):

    cd ~/projects/stirred
    STIRRED_ROOT="$HOME/Library/Application Support/Stirred-dxmt-test" \
    STIRRED_RECIPES="$HOME/Library/Application Support/Stirred-dxmt-test/recipes" \
    .build/debug/stirredctl run "rv there" --hud --keep-steam

Stop it with the same variables and `stirredctl quit`. Delete the folder to remove everything.

Not done: using this engine from Stirred itself (per-game engine choice, sharing the real prefix, rollback). It waits for the
visual check above. Wine and DXMT are LGPL: the patch and script are the corresponding source for the rebuilt `winemac.so`.
