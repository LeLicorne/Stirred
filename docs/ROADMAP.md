# Roadmap

Ideas ordered from most to least valuable (product/UX view). Status: **Done**, **Partly**, **Queued**.

| # | Idea | Status | Notes |
|---|---|---|---|
| 1 | **"Will it run?" before installing** (verdict from our tests, anti-cheat registry, DirectX version, Steam Deck status) | **Done** | "Check a game" tab and `stirredctl check`. Grow the anti-cheat registry in `recipes/steam/`. Deck status is a hint, not a promise |
| 2 | **Whole owned library ranked by compatibility** | **Done** | "All my games" tab and `stirredctl owned`. Owned games come from Steam's own cache files (`packageinfo.vdf` + `appinfo.vdf`): no API key, no network, instant. Store details (DirectX 12, anti-cheat, launchers) are then fetched slowly in the background and cached on disk |
| 3 | **"It doesn't work" diagnosis** with a suggested fix | Partly | Session reports already add advice (Unity on Vulkan, anti-cheat, DXMT) and "Copy report" exists. Missing: one button that diagnoses the last launch and applies the fix |
| 4 | **Install from Stirred** with progress | **Done** | Install in "Check a game"; download progress and size on Library cards; Steam closes after the download if Stirred started it. Steam still shows its own "Install" window to accept |
| 5 | Per-game presets Performance / Balanced / Quality | Queued | Needs per-engine settings in recipes (Unity arguments, Unreal `Engine.ini`) and expected FPS on 16 GB |
| 6 | Detect games with a native Mac version | **Done** | Part of the verdict ("play that one") |
| 7 | Pre-launch tasks in recipes (Warframe launcher update as an "Update" button) | Queued | Today: `Scripts/setup-warframe-launcher.sh` + `stirredctl run warframe --via-steam` |
| 8 | Community recipes + anonymous "report result" | Queued | The lever for scale. Opt-in only, GitHub-hosted signed JSON, needs a privacy design and moderation |
| 9 | Other stores (GOG first, then Epic via Legendary) | Queued | Plug into `GameStoreProvider`; one store at a time, each is fragile |
| 10 | Disk management: size per game, move to an external disk, low-space alert | Partly | Size is shown on cards; uninstall is done |
| 11 | Auto-update of engine and components with rollback | Queued | Keeps Stirred alive as Wine/DXVK move; pin versions by SHA-256 as setup does |
| 12 | Controller navigation, full screen, menu-bar mode | Queued | |

## Distribution
Notarization (99 EUR/year) removes the "Open Anyway" step, Sparkle gives app updates, a Homebrew cask eases install. All queued.

## Strategic risks and bets
- Rosetta 2 is being reduced after macOS 27: needs a plan (ARM64 Wine + x86 emulation) before investing much more.
- The Steam display fix depends on a fragile detail of Steam's client.
- Possible bet: a plain link "Play in the cloud (GeForce NOW)" for games blocked by anti-cheat (no integration, just a link).
- Not doing: telemetry on by default, anti-cheat bypass, redistributing D3DMetal/GPTK, a store of our own.
