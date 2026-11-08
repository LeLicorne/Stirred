# Known issues, findings and workarounds

Measured on an Apple M4, 16 GB, macOS 27, Wine staging 11.21 (Gcenx), DXVK-macOS 1.10.3.

## Graphics

- **DXMT (DX11→Metal) does not work** on this Wine: "Failed to create metal view, it seems like your Wine has no exported
  symbols needed by DXMT". It would need a Wine built with `-fvisibility=default`.
- **Official DXVK 2.x/3.x does not start on macOS**: it requires `geometryShader`, which Metal does not have.
  The Gcenx **DXVK-macOS 1.10.3** fork works and is what Stirred uses.
- DXVK logs MoltenVK limitations that can make an object or effect invisible: *"Render pipeline compile failed ... int4 cannot
  be read using MTLAttributeFormatUInt4"* and *"Transform feedback not supported"*. Session reports count them.
- DirectX 12 (vkd3d-proton) is not wired up. Games that import `d3d12.dll` are forced to DX11 through their recipe when possible.

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
