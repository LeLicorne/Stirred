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

## The Wine patch, piece by piece (`Patches/dxmt/`)

`winemac-stirred.patch` is applied to the staged Wine 11.21 sources, then `window_dxmt.c.inc` is appended to `window.c`.

| Change | Why |
|---|---|
| `macdrv_functions` table + compatibility layer (`window_dxmt.c.inc`) | DXMT finds Wine's Metal hooks through it and reads CrossOver's window-data layout |
| The view created for DXMT is shown, sized to the client area and starts at the content view's origin | Wine creates views hidden (uniform grey window); the client rect is in screen coordinates, so using it as the frame shifted the picture by the window's own position |
| The view follows the client size on every window change (`dxmt_sync_client_view`) | switching resolution or to full screen left the picture at its old size (grey bar, mouse offset) |
| The window-surface flush no longer hides a DXMT view (`surface.c`) | Wine hides the client view whenever GDI repaints the window, and only its own Vulkan/OpenGL surfaces show theirs again: after any resize the game window stayed white |
| A cursor hidden by the game stays hidden while the app is active (`cocoa_app.m`) | Wine brought it back whenever no Wine window was under the pointer |
| Opt-in cursor trace: `touch /tmp/stirred-cursor-debug`, play, read `/tmp/stirred-cursor.log` | to find out why a hidden cursor still shows in some games (open issue) |

`Scripts/test-dxmt-geometry.sh` checks the placement without a game: `Tests/Integration/d3d11_geometry.c` fills its window with magenta,
a screenshot is measured (`magenta_box.swift`) and compared with the client area Windows reports, for a window, a move, a resize with and
without `ResizeBuffers`, and a borderless full-screen window. All five match on 2026-11-16 (M4, macOS 27).

Open: the cursor still visible in RV There Yet? during play (needs the trace above from a real session); Aniimo's mouse offset and grey bar
are expected to be fixed by the two view changes but were not re-checked in the game itself.
