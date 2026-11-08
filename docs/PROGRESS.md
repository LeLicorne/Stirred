# Status and next steps

Last updated 2026-11-07. The detailed day-by-day log lives in git history (`git log -- docs/PROGRESS.md`).

## Decisions (fixed)
Apple Silicon only · 0 EUR (no paid Apple account, ad-hoc signed, not notarized) · 100% open source (no D3DMetal/GPTK) ·
GPL-3 · English UI/code/docs · SwiftUI native look · never type credentials, never bypass anti-cheat or DRM ·
test with a secondary Steam account · downloads only from the sources listed in THIRD_PARTY_LICENSES.md.

## Works
- App (Library, Activity, Logs, first-run setup) and CLI on a shared `Launcher`; 41+ unit tests.
- Verified games: Muck, HoloCure, Warframe, For The King II. See README and docs/KNOWN-ISSUES.md for numbers and workarounds.
- "All my games" (whole owned library ranked offline from Steam's cache files, refined from the store with a disk cache), "Check a game", install from Stirred, uninstall.
- Session reports (CPU/GPU sampling, redacted logs, findings), latency profiles, power warnings, bounded logs.

## Not done / ideas, roughly by value (full ordered list in docs/ROADMAP.md)
1. Verify first-run setup on a second machine. It was tested from scratch in a throw-away data folder (`STIRRED_ROOT`): Wine and DXVK downloaded and
   checksum-verified, prefix created, Steam installed and updated, display fix applied, a rendered sign-in window. Only the sign-in is manual.
2. App button to update Warframe through its launcher (today: `Scripts/setup-warframe-launcher.sh` + `stirredctl run warframe --via-steam`).
3. Install a game by appid from the app (`stirredctl install <appid>` exists).
4. DX9 support (d3d9.dll is in the DXVK package but not installed per game) and DX12 (vkd3d-proton).
5. Trackmania / Ubisoft Connect; other stores (GOG, Epic via Legendary) through `GameStoreProvider`.
6. Controller navigation and full-screen mode; menu-bar mode; automatic Steam updates handling.
7. Real FPS capture (needs a DXVK patch or Metal HUD parsing).
8. Rosetta 2 is being phased out after macOS 27: long-term plan needed.

## Working rules for this repo
- Run lint/build/tests once at the end of a work block with `-j 4`; do not saturate the CPU.
- Kill Wine with `wineserver -k` (or the app's Quit), not `kill -9`.
- Debug aids: `stirredctl run <game> --watch --hud`, `open build/Stirred.app --args -section activity|logs|library`,
  window capture via `screencapture -l <windowid>` (needs the Screen Recording permission). Per-window captures of Metal windows are black.
