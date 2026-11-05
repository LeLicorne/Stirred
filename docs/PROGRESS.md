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

## NOT done / where I stopped
1. **Steam login not done**: needs the user (I cannot type passwords). Steam was left running at the login
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
