# Stirred

Play Windows Steam games on Apple Silicon Macs in one click, locally (no streaming latency).
Free, open source (GPL-3), built only from open-source components.

> **Status: early prototype (WIP).** Not affiliated with Valve, Apple or any game publisher.
> Steam is a trademark of Valve.

## How it works
Stirred orchestrates Rosetta 2, [Wine](https://www.winehq.org/) (LGPL), and [DXMT](https://github.com/3Shain/dxmt)
(LGPL-2.1, DirectX 11 → Metal) to run the **official** Windows Steam client in an isolated prefix,
then launches your games through it. It never touches your credentials and never bypasses DRM or anti-cheat.

Games using kernel anti-cheat (Easy Anti-Cheat, BattlEye, Vanguard…) do not run on macOS;
Stirred flags them instead of trying to work around it.

## Try it (developers)
```sh
sh Scripts/assemble-engine.sh        # downloads Wine + DXMT, builds engine "stirred-*"
swift build && swift test
.build/debug/stirredctl doctor
.build/debug/stirredctl init-prefix
```
Then install Steam in the prefix, log in with a **secondary** account, and use `stirredctl library|plan|run`.
See `docs/PROGRESS.md` for the current state and next steps.

## Layout
- `Sources/StirredCore`: all logic (engine, prefix, Steam provider, recipes, launch planner)
- `Sources/stirredctl`: debug CLI
- `recipes/steam/<appid>.json`: per-game compatibility knowledge
- `Scripts/`: engine assembly
