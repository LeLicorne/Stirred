# Stirred — progress log (read this first when resuming)

Last updated: 2026-11-05. Plan of record: `/Users/baptiste/.claude/plans/fait-moi-un-plan-abstract-pelican.md`.

## Decisions (user-confirmed)
Apple Silicon only · 0 € budget (no Apple Developer account, no notarisation) · 100 % open-source stack
(no D3DMetal/GPTK, ever) · GPL-3 · solo use first · English code/docs/UI · Claude writes, user reviews and
learns Swift · SwiftUI native look · test with a **secondary Steam account** · local git only for now.
MVP scope: Steam login + library, one-click Play, automatic per-game settings, controller + full screen.
Later stores: GOG, Epic (Legendary), Ubisoft Connect/EA/Battle.net.
No anti-cheat bypass: flag the game, offer offline mode only (`-insecure` for CS2).

## Machine (checked 2026-11-05)
macOS **27.0.1** (Rosetta still fully available; Apple plans to reduce it after 27: top long-term risk),
Xcode 27.0, Swift 6.4, M4 / 16 GB, 317 GB free, Homebrew 7.0.12, `gh` logged in as LeLicorne.
A native macOS Steam.app also exists; Stirred uses its own isolated Windows Steam.

## Done
- **Phase 0 spike (mostly)**: Wine staging 11.21 (Gcenx build, WoW64) + DXMT v0.80 (LGPL-2.1) overlaid
  into one engine `stirred-dev`; prefix created in ~24 s; official `SteamSetup.exe` installed silently;
  Steam self-updated and its UI (steamwebhelper/CEF) runs with `-no-cef-sandbox -cef-disable-gpu-compositing`;
  Direct3D 11 initialises on the M4 through DXMT.
- **Phase 1/2 core** in Swift package: `StirredCore` (paths, engine locator, WineRunner, VDF parser,
  Steam provider + `GameStoreProvider` protocol, recipes, graphics detection, LaunchPlanner) and the
  `stirredctl` CLI (`doctor`, `init-prefix`, `steam`, `library`, `plan`, `run`). 13 unit tests pass.
- Seed recipes in `recipes/steam/*.json` (JSON, not YAML, to avoid a dependency). None are verified.
- `Scripts/assemble-engine.sh` reproduces the engine assembly.

## Files outside the repo (not in git)
`~/Library/Application Support/Stirred/` → `downloads/` (archives + SteamSetup.exe),
`engines/stirred-dev` (the working engine; raw `wine-staging-11.21` and `dxmt-0.80` kept beside it),
`prefixes/steam`, `steam-first-run.log`, `logs/`.

## Steam black window: SOLVED (2026-11-05, evening)
Symptom: Steam window black under Wine 11 (also without DXMT, so DXMT is not the cause; GPU flags did not help).
Fix: replace `steamwebhelper.exe` (in every `bin/cef/cef.win*`) with our wrapper (`Wrapper/steamwebhelper_wrapper.c`,
cross-compiled with Homebrew `mingw-w64`) that starts `steamwebhelper_real.exe` with `--disable-gpu --single-process`.
Steam restores the original at boot unless started with `-noverifyfiles -nobootstrapupdate`.
Procedure: `Scripts/install-webhelper-wrapper.sh` then start Steam with those flags. Verified by window capture
(`screencapture -l <windowid>` works; window ids via CGWindowList). Idea came from the open-source project
notpop/steam-on-m1-wine (wrapper written from scratch here, not copied).
**Open risk** (same project reports it): with Wine 11, D3D11 *game* windows may render transparent through upstream
DXMT; they needed a patched DXMT + a Wine build with `-fvisibility=default`, and a virtual-desktop wrapper. Test a real game
before assuming DXMT works. Also: Steam updates may replace the helper again → redeploy wrapper before each launch.
Currently the working Steam run uses the RAW engine `wine-staging-11.21`, not `stirred-dev` (DXMT overlay).


## Session 2026-11-06 findings (read before debugging Steam again)
- **The "Steam won't start after relaunch" bug was MY script**, not DXMT: `install-webhelper-wrapper.sh` once copied a
  *rebuilt wrapper* over `steamwebhelper_real.exe` (it compared hashes), so the wrapper launched itself forever.
  Fixed: classify by file size (<500 KB = wrapper), refuse if `_real` is not Valve's 7.5 MB file, only handle `cef.win64`.
  Recovery if it happens again: delete `steamwebhelper_real.exe`, start Steam once WITHOUT `-noverifyfiles` so it restores Valve's
  file, then rerun the script.
- Steam UI works on BOTH engines (raw `wine-staging-11.21` and `stirred-dev` = +DXMT). Saved login survives restarts.
  Use `STIRRED_ENGINE=<dir under engines/>` to pick an engine; only one engine per running Steam/wineserver.
- Never `kill -9` casually: use `wineserver -k` first. Debug tooling: window list via CGWindowListCopyWindowInfo +
  `screencapture -l <id>` (needs the Screen Recording permission the user granted).
- Installed test game: **Cat Purrtrol: Find All 100!** (appid 2895990, Unity 2019.3.15, 32-bit, 874 MB). Game process starts but
  **crashes at startup inside UnityPlayer.dll** (Player.log: "Crash!!!" + stack, before any renderer line). Seen on the raw engine
  (loads OPENGL32 => wined3d). Test on `stirred-dev` (DXMT) was launched but result not confirmed (log timestamp ambiguous).
  Next: check `Player.log` freshness, try `-force-d3d11` / `-force-gles` style Unity args via recipe `launch_args`, check the
  32-bit WoW64 path (upstream DXMT notes say 32-bit Unity needed a patched DXMT/Wine build), and try a 64-bit DX11 game.
- User shared a test-account password in chat: told to change it; it was NOT stored anywhere.


## Graphics backend decision (2026-11-07) — READ THIS
Results of real tests on M4 / macOS 27 / Gcenx Wine 11.21 (both staging and devel):
- **DXMT v0.80: unusable for now.** Fails with "Failed to create metal view, it seems like your Wine has no exported symbols
  needed by DXMT". Needs a Wine built with `-fvisibility=default` (rebuild of macdrv). Revisit only if we build Wine ourselves.
- **DXVK 3.1.1 (official): unusable on macOS.** Needs `geometryShader`, which MoltenVK/Metal lacks ("No adapters found").
- **DXVK-macOS 1.10.3 (Gcenx fork, zlib): WORKS.** `Tests/Integration/d3d11_clear.c` (own D3D11 smoke test) creates the device on
  the M4, presents frames, and the user SAW the pulsing colours on screen (per-window `screencapture -l` shows black for
  Metal-backed windows: do not trust it for game windows; ask the user or capture the screen region with the window on top).
- Therefore LaunchPlanner defaults to **dxvk** for DX9/10/11. DX12 (vkd3d-proton) still untested.
- Install per executable, NOT via env vars: Steam is already running when a game starts, so env vars set by `stirredctl run`
  never reach the game. `DXVKInstaller` copies DLLs next to the exe and sets `HKCU\Software\Wine\AppDefaults\<exe>\DllOverrides`.
  Component: `Scripts/install-components.sh` -> `$ROOT/components/dxvk-macos-1.10.3`.
- **32-bit Unity 2019 (Cat Purrtrol) still crashes at startup** with or without DXVK, on staging and devel: access violation in
  UnityPlayer.dll then "Exception frame is not in stack limits" (Mono init, WoW64 32-bit on macOS). Not a graphics issue.
  Do not spend more time on it; use 64-bit games for validation.
- Engine `stirred-dev` still has the DXMT overlay (breaks nothing visible). Prefer `STIRRED_ENGINE=wine-staging-11.21`.
- Next: install a 64-bit DX11 game (user clicks Install in the Steam window), run `stirredctl run <appid>`, ask the user what they
  see, record the recipe. Then DX9 via the same DXVK-macOS (d3d9.dll is in the package but not installed yet).


## Muck verified + performance findings (2026-11-07, evening)
- **Muck (appid 1625450) is playable** (recipe verified). Unity 2019.4, 64-bit, DX11 through DXVK-macOS 1.10.3 + MoltenVK.
- **Biggest FPS factor was macOS Low Power Mode + battery**: 24-30 FPS (flat ~30 even in the nearly empty menu) -> **~130 FPS** once
  plugged in with Low Power Mode off and graphics on low. `PowerState`/`PowerAdvice` now warn in `doctor` and `plan`/`run`.
- Input latency: `dxgi.maxFrameLatency=1` + vsync off (`--latency lowest`) felt "much better" to the user; in-game vsync off helped too.
- Per-game `dxvk.conf` also supports `--hud` (fps, frametimes, drawcalls, pipelines, compiler, memory) and `--async`
  (shader compilation in background). Both are opt-in flags of `stirredctl run`.
- HoloCure (appid 2420510, Windows-only, GameMaker, 64-bit) is installed but not tested yet: Steam showed a "Grab a controller" dialog
  that must be dismissed by the user (clicks on Wine dialogs did not register at first).
- Still open: Wine input path latency (needs a Wine rebuild to change), MoltenVK tuning (perf only), CPU vs GPU bound at high graphics
  (not measured now that power is fixed), Warframe/Trackmania (not installed), DX9 (d3d9.dll in package, not wired), DX12.


## Session reports (2026-11-07, late) — how to use
- `stirredctl run <appid> --watch [--seconds N]` records a session in `logs/sessions/<stamp>-<appid>/` (symlink `latest`):
  `report.md` (read this first), `session.json`, `samples.csv` (GPU %, game CPU %, RSS every 3 s), `excerpts/*` (Unity Player.log,
  Steam gameprocess/console logs, DXVK logs, redacted: user name/home removed). `stirredctl report [dir]` regenerates it after playing.
- Steam is now started with `DXVK_LOG_PATH=logs/dxvk`, `DXVK_LOG_LEVEL=info` (games inherit Steam's env), `MVK_CONFIG_LOG_LEVEL=1`.
- Logs are bounded: `LogRotation` (20 MB) and a former 7 GB `steam-client.log` was truncated.
- Findings are hints: GPU util is whole-machine, CPU is approximate (`ps`). FPS are NOT logged: use `--hud` + a screenshot.
- Unity buffers Player.log: if the report is generated while the game still runs, "Key log lines" can be incomplete.
- Tests: 27 pass (`swift test -j 4`).


## The Mac app exists (2026-11-07, night) — START HERE
- `Scripts/build-app.sh` builds `build/Stirred.app` (ad-hoc signed, 0 EUR). `open build/Stirred.app`.
  Tabs: **Library** (cover art from Steam's public CDN, compat badge from recipes, per-game latency picker, Play/Stop,
  FPS-overlay toggle, warnings for Low Power Mode/battery), **Activity** (recorded sessions: report + CPU/GPU chart),
  **Logs** (live tail of Steam/DXVK logs). Sidebar footer: Steam state + Open Steam / Quit + engine name.
- Play = `Launcher.play`: starts Steam silently if stopped, waits until "Logged On", installs DXVK for the game, opens a session,
  asks Steam to launch, then the app samples CPU/GPU until the game exits and writes the report. Same code as `stirredctl`.
- Shared logic moved to `Sources/StirredCore/Launcher.swift`; `stirredctl run muck --watch` accepts a name or appid.
- Default engine is now `stirred-wine-11.21` (clone of raw Wine staging, no DXMT); no `STIRRED_ENGINE` needed anymore.
- NOT verified yet: Steam `-silent` start under Wine (window may still appear / login needed), Play button end-to-end from the UI,
  first-run when no engine/prefix exists (the app only shows an error banner), installing games without the Steam window.
- Ideas next: first-run onboarding that runs assemble-engine/install-components, "Install by appid" (`steam://install/<id>`),
  controller navigation, menu-bar mode, FPS capture (needs a DXVK patch or Metal HUD), HoloCure/Trackmania tests.


## UI polish + report accuracy (2026-11-07, night)
- Activity now shows a native summary (metric cards, CPU/GPU chart, findings with icons, "Played" time = first to last sample,
  collapsible full report); list is top-aligned and auto-selects the latest session. Logs tab: search + "Errors only".
  Library: equal-height cards, Cat Purrtrol greyed out (recipe `unsupported`, verified).
- `open build/Stirred.app --args -section activity|logs|library` opens a tab directly (used for screenshots).
- **Report bug fixed**: a session was wrongly flagged as crashed. Causes: (1) Player.log of *other* games was read (now only the log whose
  first lines mention the game's install folder, `installDirName`); (2) Steam's `assert_<exe>.dmp` is a non-fatal assertion, not a crash
  (now a finding, not a crash flag; only non-assert dumps for this exe count); (3) regenerating an old report re-read the newest logs
  (now bounded to [start-60 s, end+180 s] and keeps the original end time).
- New finding: counts of DXVK/MoltenVK problems in the DXVK log: "Failed to compile pipeline" (MoltenVK: int4 vertex attributes read as
  UInt4) and "Transform feedback not supported" (D3D11 geometry-shader stream output). They can make objects/effects invisible. Muck shows
  ~9 pipeline failures + 1 stream-output error per run; the user saw no visible problem yet. Worth investigating if a game looks wrong.
- 32 tests pass.

## NOT done / where I stopped
1. **Steam login not done**: Steam is now running and shows the login form (no more black window). User must sign in with the test account.
   screen (started with `stirredctl steam`-equivalent flags). If it is closed: `swift run stirredctl steam`.
2. No real game launched yet → all recipes `verified: false`, performance unmeasured.
3. DXVK + MoltenVK + vkd3d-proton **not installed** (only DXMT). DX9 games need DXVK+MoltenVK, DX12 needs
   vkd3d-proton. LaunchPlanner already reports them in `requiredComponents`, but nothing installs them yet.
4. No component installer (vcredist/.NET via winetricks), no engine downloader inside Swift (the script does it).
5. No SwiftUI app, no onboarding, no controller/full-screen mode, no Steam "keep warm" option.
6. Overlay Steam and cloud saves untested.
7. DXMT builtin install replaced Wine's own d3d11/dxgi in the engine copy: confirm it does not break
   non-DXMT games (keep the raw engine to compare).

## Next session, in order
1. User logs into Steam (test account). Install a small free DX11 game; `stirredctl library`, `plan`, `run`.
2. Record result (works/crash, flags needed, time to menu) in the recipe and set `verified: true`.
3. Test Trackmania/Warframe (Ubisoft Connect needed for Trackmania), then CS2 offline with `-insecure`.
4. Add DXVK + MoltenVK to `assemble-engine.sh` and test a DX9 game.
5. Port `assemble-engine.sh` into Swift (`EngineManager` with checksums), then start the SwiftUI shell.
6. Learning track for the user: explain Swift concepts met in `Sources/StirredCore` (enum with associated
   values in VDF, `async/await` + continuation in `WineRunner.runAndWait`, Swift Testing macros).

## Constraints to remember
- Run lint/build/tests once at the end of a work block, `-j 4`; never saturate the CPU (CLAUDE.md).
- Never type credentials; never bypass anti-cheat/DRM; no D3DMetal/GPTK; downloads only from the sources
  the user approved (Gcenx, 3Shain/dxmt, doitsujin/dxvk, KhronosGroup/MoltenVK, Valve CDN).
