# Known issues, findings and workarounds

Measured on an Apple M4, 16 GB, macOS 27, Wine staging 11.21 (Gcenx), DXVK-macOS 1.10.3.

## Graphics

- **DXMT (DX11→Metal) needs the optional DXMT engine**: the standard Wine hides the symbols DXMT needs ("Failed to create metal view").
  `Scripts/build-dxmt-engine.sh` builds an engine that works (see docs/DXMT.md); games set to DXMT fall back to DXVK without it.
- **Official DXVK 2.x/3.x does not start on macOS**: it requires `geometryShader`, which Metal does not have.
  The Gcenx **DXVK-macOS 1.10.3** fork works and is what Stirred uses.
- DXVK logs MoltenVK limitations that can make an object or effect invisible: *"Render pipeline compile failed ... int4 cannot
  be read using MTLAttributeFormatUInt4"* and *"Transform feedback not supported"*. Session reports count them.
- DirectX 12 does not work on this stack (checked 2026-11-24): vkd3d-proton 3.1 (latest release, GitHub, SHA-256 `b85ea821…`) refuses to create a device
  on MoltenVK: "vkd3d_init_device_caps: Lacking support for transform feedback", `D3D12CreateDevice` returns `E_INVALIDARG`
  (probe: `Tests/Integration/d3d12_clear.c`). Metal has no transform feedback, so this is not a setting. Games are forced to DirectX 11 when they
  allow it (`-dx11` for Unreal, done automatically); DX12-only games do not run.

## Performance

- **macOS Low Power Mode and battery power cap games around 30 FPS** (Muck: 24-30 FPS → ~130 FPS once plugged in with the mode off).
- Input lag: the `lowest` latency profile (1 frame queued, V-Sync off) felt much better; turning V-Sync off in the game helps too.
- FPS cannot be written to a log (DXVK only draws them): use the "FPS overlay" toggle and take a screenshot.

## Steam under Wine

- Black Steam window → the display fix (see ARCHITECTURE). If a Steam update replaces the helper, start Steam from Stirred again
  (it re-applies the fix on every start).
- A windowless start needs a remembered login. The first start of a fresh install shows the sign-in window.
- Steam's *"Grab a controller and kick back!"* prompt blocks a normal launch and its OK button ignored clicks. Games
  affected (HoloCure) use `launch_mode: direct`: no Steam overlay or playtime tracking, but no prompt.
- `assert_<game>.exe_*.dmp` files in Steam's `dumps` folder are non-fatal assertions, not crashes.
- Steam keeps showing "Stopping" while any process it tracks for the game is alive. **Stop** in Stirred kills the whole folder's processes.

## Presets
- Presets (Faster / Balanced / Prettier) only change what Stirred controls and has verified: frame queue and V-Sync (input delay),
  background shader compilation, a 60 FPS cap. A render-resolution preset was tried and dropped: Unity's `-screen-width/-height` is overridden
  by games that set their own resolution at startup (Muck still rendered at 1800x1169).

## Games

- **Unity 2022+ shows missing texture tiles**: Unity picks Vulkan by default (its log says "graphics device is Vulkan"), which goes
  through MoltenVK and corrupts textures. Stirred now adds `-force-d3d11` to every Unity game (detected by `UnityPlayer.dll`),
  so the game uses DirectX 11 through DXVK. **Always start games from Stirred**: from Steam's own window DXVK and these launch
  arguments are not applied.
- **32-bit Unity 2019** (Cat Purrtrol) crashes at startup: access violation in `UnityPlayer.dll`, then *"Exception frame is not in stack limits"*
  (32-bit code in Wine's WoW64 mode on macOS). Same with Wine devel, with or without DXVK. 64-bit Unity games work.
- **Warframe**: its launcher (`Tools/Launcher.exe`, Chromium) is blank under Wine and hashes itself, so the game is started
  directly in DX11 (recipe). The game asks for an update after each patch; to update:
  `Scripts/setup-warframe-launcher.sh`, then `stirredctl run warframe --via-steam`, wait for `Launcher.log` to say
  *"Finished Preprocess"*, close the launcher (its window stays white and its GPU process burns CPU), then play normally.
  The launcher's hardware check needs a working D3D11 (DXVK provides it) while its Chromium must have no shader compiler.
- **Orcs Must Die! 3** (Unreal Engine 4): the 2D interface draws, the 3D scene stays black. DXVK is loaded; MoltenVK fails to compile 2
  pipelines ("Fragment input(s) `user(locn2)` mismatching vertex shader output type(s) or not written by vertex shader": Direct3D allows
  a pixel shader to read a value the vertex shader never wrote, Metal does not). Replacing the engine's MoltenVK by 1.4.2 did not change it.
  Also tried with no change: Unreal `-sm4`; an `Engine.ini` switching off auto-exposure, tiled/clustered lighting, volumetric fog, the
  translucency lighting volume, SSR and AO; DXVK options `constantBufferRangeCheck`, `zeroWorkgroupMemory`, `useRawSsbo`,
  `cachedDynamicResources`; and Wine's own D3D11, which refuses to start ("Feature Level 11.0, Shader Model 5.0 is required").
  The pipeline that fails (VS + GS + PS) probably is not the cause of the black scene, so the real cause is unknown.
  Left to try, both heavy: DXMT (needs a Wine built with exported macdrv symbols) or a patched DXVK.
- **Trackmania**: `Trackmania.exe` only starts Ubisoft Connect, which spins at ~100% CPU on several processes and never starts the game
  (`launcher_log`: "StartReqError ... code: 109"; missing `HKCR\uplay` keys). Wrapping `UplayWebCore.exe` calmed Chromium but not the service.
- Kernel anti-cheat (EAC, BattlEye, Vanguard) never works on macOS; Stirred flags such games and never tries to bypass them.

## Long-term risk

Rosetta 2 is to be reduced after macOS 27 (check Apple's current notes). Stirred needs it to run x86 Wine.

## Game updater (Warframe)
- "Update game" prepares the game's launcher for Wine (DXVK next to it, shader compiler disabled for it only) and runs it through Steam. Checked 2026-11-08 on an up-to-date game: Steam started the launcher and it ended by itself after about 20 s. An actual update (when Warframe asks for one) has not been re-tested since this button replaced the manual script.
- Only recipes with an `updater` entry get the button (Warframe today).

## Disk management
- A moved game keeps its folder in `steamapps/common` as a link to the other disk; Steam's own files are not edited. Checked 2026-11-08 with a throw-away disk image: copy across volumes, Muck detected running through the link, move back. Not checked on a real external disk (exFAT/NTFS drives may behave differently) nor with a game that Steam updates while moved.
- If the disk is unplugged the card shows a red disk icon and Play fails; plug it in again.
- A moved game cannot be uninstalled from Stirred until it is moved back.
- Only Steam games, and only while nothing is downloading. Steam is closed during the move.
- "Can be cleaned" only deletes setup downloads and Steam's shader cache, never saves, games or prefixes. The low-space warning appears under 20 GB free.

## Engine updates
- Only engines listed in `Resources/engines.json` can be installed (pinned by SHA-256), so a new Wine reaches users with a Stirred release. "Check for newer Wine builds" only reports; it never installs.
- Switching saves the prefix's registry and Windows system files with APFS cloning (not games, not Steam), closes Steam, runs `cmd /c echo` with the new engine and goes back by itself if that fails. The check is small: a game that breaks on the new Wine is not caught; use "Go back" then.
- Checked 2026-11-08 with a second copy of Wine 11.21 posing as 11.22: install, switch, rollback, then Muck started without crash. A really different Wine version has not been tried; no newer build exists yet.
- DXVK and MoltenVK are not updated this way (DXVK 2.x does not work on this stack anyway).

## Menu bar, couch mode, controller
- Menu bar icon: Steam state, Play/Stop per game, Couch mode, Close Steam, Open Stirred, Quit. Closing the window leaves Stirred in the menu bar.
- Couch mode (toolbar "tv" button or menu bar): full screen, one row of covers. Keys: arrows, Return (play), S (stop), Esc (leave). Controller: D-pad or left stick, A play, Y stop, B leave.
- Checked 2026-11-08: the couch view renders full screen and centered (screenshot); the selection logic is unit-tested. Not checked: a real controller (none connected), key presses (macOS refused synthetic keystrokes), the menu bar menu clicks.
- Controller events reach Stirred only while it is the front app. In a game the controller belongs to the game (Wine passes it through); Steam Input remapping is not supported.
- Only the couch view is controller-driven; the rest of the app needs mouse or keyboard.

## Black 3D scene on Unreal / some Unity games (RV There Yet?, Orcs Must Die 3)
- Symptom: menus and HUD draw, the 3D world is black. Logs show `[mvk-error] Render pipeline compile failed ... Fragment input(s) user(locn2) mismatching vertex shader output` for a pipeline with a geometry shader (MoltenVK has no geometry shaders; DXVK-macOS 1.10 skips them, so the fragment shader misses its inputs). DXVK also reports `shaderStorageImageExtendedFormats: 0`, which Unreal's post-processing needs.
- Tried: forcing DirectX 11 (`-dx11`, makes the game start), `-FeatureLevelES31` (game exits at start-up). Nothing left to try with DXVK 1.10 on this stack; a fix would need MoltenVK or DXVK changes upstream.

## DXMT retried (2026-11-08)
- DXMT v0.80 (LGPL-2.1, supports geometry shaders) refuses to start on our Wine 11.21 (Gcenx): "Failed to create metal view ... no exported symbols". `winemac.so` exports 0 `macdrv_*` symbols; DXMT needs a Wine that exposes them (CrossOver 24+ built from CodeWeavers' free sources, or a Wine built with default symbol visibility).
- Sikarugir's `WS12WineSikarugir11.0_1` engine does contain the exports but is not self-contained: `libinotify.0.dylib` and other libraries come from the Sikarugir app wrapper (`@rpath`, no LC_RPATH). With Gcenx's libraries on `DYLD_LIBRARY_PATH` wineserver runs but wineboot still fails to start.
- Left to try: take the Frameworks from Sikarugir's wrapper template, or build CodeWeavers' Wine from source (hours of compiling). Neither is done. Everything downloaded for the test was deleted.

## DXMT now works as an optional engine (2026-11-08)
- RV There Yet? draws its 3D scene with DXMT on a patched Wine (`-dxmt` engine); a solo run of ~6 min ended cleanly. Multiplayer does not work yet
  (Epic Online Services: "No online services are present", session creation times out). Orcs Must Die 3 not retested with DXMT.

## Automatic backup of game settings and saves (2026-11-08)
- Cause: deleting a throw-away copy of the Windows environment lost the controls set in a game (a human mistake, not an engine matter: settings live in the prefix, not in the engine).
- Stirred now copies, with APFS cloning (instant), each user's `AppData/Local|Roaming` (except Steam, Temp and caches), `Documents`, `Saved Games` and Steam's `userdata` into `backups/<date>-<reason>/`.
  It runs after each game (5 kept, skipped if nothing changed) and before engine switch/rollback, uninstall and move (10 kept each).
- `stirredctl backup [list|now|restore <name>]`, and Disk > "Game settings and saves" in the app. Restore needs Steam closed and takes a safety copy first.
- Not covered: the games' own files, files outside those folders (a game that writes next to its executable), and a lost disk (copies are on the same disk).

## Epic Games (2026-11-16)
- Not verified end to end yet: signing in, listing, installing and starting a real game need the account owner. What is verified: the tool downloads and
  matches its checksum, runs, reports "not signed in"; every parser and the launch command are unit-tested against Legendary's documented output.
- Legendary prints `Failed to execute script 'pyi_rth_multiprocessing'` on short commands: a helper process starts while the main one already ended.
  Harmless (exit status 0, correct output); Stirred reads standard output only.
- Games that need Epic's overlay or Epic Online Services may refuse online play; games with Easy Anti-Cheat or BattlEye do not run.
- Epic games cannot be moved to another disk from Stirred, and are not part of "All my games" (no Steam Deck data for them).

## Ubisoft Connect trial in its own environment (2026-11-16) — not conclusive
- Setup: fresh `prefixes/ubisoft`, official installer (`UbisoftConnectInstaller.exe`, 259 MB, Ubisoft's Akamai address, signed by Ubisoft Entertainment),
  silent install OK (client build 12921), standard engine.
- Result: the client starts (`upc.exe`), but its Chromium helper `UplayWebCore.exe` crashes ("Program Error") and its utility processes restart in a loop;
  no sign-in window. Wrapping the helper like Steam's (`--disable-gpu --single-process`) does not help: here the browser process is `upc.exe` itself, the
  helpers are only its children. Starting `upc.exe` directly with those flags makes it exit at once.
- The trial ran on a network where every request to `ubi.com`, `ubisoft.com` (and to the Steam store, EA and Blizzard sites) was reset, so the client's
  own log shows "Http status code is none" for all its services. The crash may or may not depend on that: **to be redone on a network that reaches Ubisoft**.
- Not tried yet: the `uplay://` registry keys (only matter once the client runs), other Wine versions.
- `Wrapper/steamwebhelper_wrapper.c` now takes `-DREAL_EXE=...` and `-DEXTRA_FLAGS=...` at build time, ready for another helper.
- EA App and Battle.net trials are waiting for the same reason (their installers could not be downloaded from this network).

### Ubisoft Connect, second trial with the network working (2026-11-24): stopped
- The client now reaches Ubisoft's services, opens, then shows "Ubisoft Connect has detected an unrecoverable error" (crash dump in its `crashes/`).
- Cause, from Wine's own trace: `UplayWebCore.exe` (its embedded Chromium) is a **32-bit** program and crashes inside `wow64cpu.dll`, Wine's layer that runs
  32-bit Windows code on this 64-bit-only build ("Unhandled page fault ... at address 7BF41135", `wow64cpu.dll` loaded at `7BF40000`). Same family as
  the 32-bit Unity crash above: a limit of Wine's WoW64 mode on macOS, not something a recipe or a wrapper fixes.
- Decision (stop criterion of the plan): Ubisoft Connect is not supported; Trackmania stays blocked. To revisit when a newer Wine (or a build with the old
  32-bit mode) is available: install it as an engine and re-run `UbisoftConnect.exe` in `prefixes/ubisoft`.

### Battle.net and EA App trials (2026-11-24): waiting for a human click
- Both official installers (downloaded from Blizzard's and EA's own addresses) start in their own Windows environment and **draw their window correctly**
  under Wine (Battle.net: language picker; EA App: welcome screen with its user agreement). Both are 32-bit bootstrappers that worked, unlike Ubisoft's helper.
- They stop there: the next step is a click (and, for EA, accepting EA's agreement), which only the user may do. Continue with
  `Scripts/try-launcher.sh battlenet` or `Scripts/try-launcher.sh ea`, then `... run` once installed. Integration into Stirred only if the client
  then shows its sign-in and library.
- Battle.net, by hand (2026-11-24): first run ended with "Battle.net Update Agent" error BLZBNTBTS0000005C (the Agent started, wrote 3 log lines and hung).
  With Wine's `locationapi` disabled (`HKCU\Software\Wine\DllOverrides`, now done by `try-launcher.sh`) the Agent answers requests and reads its
  product database. Whether the installation then completes is not known yet.
- Battle.net, follow-up (2026-11-24): with `locationapi` disabled the installer **completes** (client 2.42.1 in `Program Files (x86)/Battle.net`).
  The client itself then hangs right after "Opening IPC shared memory ... mode=server" (CPU 0 %, no window, no crash). Trial stopped there, per the plan's
  one-session rule. Next idea if revisited: find what it waits for (a named mutex or shared-memory section, `WINEDEBUG=+sync,+file`).
