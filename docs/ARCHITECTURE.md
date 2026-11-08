# Architecture

## Layers

```
Stirred.app (SwiftUI)  ──┐
stirredctl (CLI)        ──┼──>  StirredCore (Swift package: all logic, tested)
                          │       Launcher  ← the single entry point used by both front ends
Wine (Gcenx staging)   <──┘       SetupManager · SteamProvider · LaunchPlanner · SessionRecorder · ...
  + DXVK-macOS 1.10.3 (DX9/10/11 → Vulkan)
  + MoltenVK (Vulkan → Metal, bundled in the Wine build)
  + Rosetta 2 (x86_64 → arm64)
```

## StirredCore

| File | Role |
|---|---|
| `Launcher.swift` | Engine/Steam lookup, `play`, Steam start/quit, sessions list, `watch` sampling loop |
| `Setup.swift` | First-run installer: Rosetta check, Wine, DXVK, prefix, Steam, Steam first start. Pinned SHA-256, resumable |
| `WebHelperWrapper.swift` | Steam black-window fix (see below) |
| `Steam.swift` | `GameStoreProvider` protocol, Steam client flags, library from `appmanifest_*.acf`, launch modes |
| `LaunchPlanner.swift` | Pure function: recipe + detected APIs + hardware → backend, env, args, warnings |
| `Recipe.swift` | `recipes/steam/<appid>.json` (status, backend, launch mode, args, latency, notes) |
| `GraphicsSetup.swift` | PE architecture, per-game DXVK install + `dxvk.conf` (latency profiles, HUD, async) |
| `SessionReport.swift` | Session recording, CPU/GPU sampling, log collection with redaction, `report.md` |
| `VDF.swift`, `GraphicsDetection.swift`, `PowerState.swift`, `LogRotation.swift`, `WineRunner.swift`, `Engine.swift`, `Paths.swift` | Small focused helpers |

New stores (Epic, GOG...) plug in through `GameStoreProvider`.

## Data on disk (`~/Library/Application Support/Stirred`, override with `STIRRED_ROOT`)

```
engines/stirred-wine-11.21/   Wine (a "stirred-*" folder is picked automatically, newest name first)
components/dxvk-macos-1.10.3/ DXVK x32/x64
prefixes/steam/               Wine prefix holding Windows Steam and the games (steamapps)
downloads/                    cached archives (verified by SHA-256)
logs/                         steam-client.log (rotated at 20 MB), dxvk/, sessions/<date>-<appid>/
```

## What happens on Play

1. `LaunchPlanner` builds a plan (backend, latency profile, warnings, launch mode).
2. Steam is started if needed (windowless if a login is remembered), then Stirred waits for "Logged On".
3. DXVK DLLs are copied next to each game executable and Wine is told to use them **for that executable only**
   (`HKCU\Software\Wine\AppDefaults\<exe>\DllOverrides`). Not by environment variables: Steam is already running, so
   per-game variables never reach the game.
4. A session is opened, the game is launched (`steam` mode: `-applaunch`; `direct` mode: the exe itself with `SteamAppId`).
5. The process is sampled every 3 s until it exits; the report is written.
6. Clean-up: processes left in the game's folder are killed (`stopGame`); if Stirred started Steam for this session and the user did not
   open it by hand, Steam is shut down gracefully (`steam.exe -shutdown`, so cloud saves finish syncing), then anything left is killed.

## Uninstall

`Uninstall.swift` does what Steam's "Delete local content" does, without Steam's dialog: it deletes `steamapps/common/<folder>`, the shader
cache / downloading / temp / workshop leftovers for the app id, and `appmanifest_<id>.acf` (last, so a half-finished delete still shows the
game). Safety: the folder must resolve (symlinks followed) to exactly one level under `steamapps/common`, the app id must be numeric, and a
running game blocks it. Steam is closed first because it would keep believing the game is installed.

## The Steam display fix

Under Wine 11 the Chromium behind Steam's UI paints a black window. `steamwebhelper.exe` is replaced by a tiny wrapper
(`Wrapper/steamwebhelper_wrapper.c`, compiled copy in `Resources/wrappers/`) that starts the original, saved as
`steamwebhelper_real.exe`, with `--disable-gpu --single-process`. Steam is started with `-noverifyfiles -nobootstrapupdate`
so it does not restore the original. `WebHelperWrapper` tells the two apart **by file size, never by hash**
(a hash comparison once made the wrapper copy itself over the real helper and launch itself forever; a test covers it).

## Rebuilding the wrapper

`Scripts/build-wrappers.sh` (needs `brew install mingw-w64`). Only needed when the C file changes.
