# Roadmap

Ideas ordered from most to least valuable (product/UX view). Status: **Done**, **Partly**, **Queued**.

| # | Idea | Status | Notes |
|---|---|---|---|
| 1 | **"Will it run?" before installing** (verdict from our tests, anti-cheat registry, DirectX version, Steam Deck status) | **Done** | "Check a game" tab and `stirredctl check`. Grow the anti-cheat registry in `recipes/steam/`. Deck status is a hint, not a promise |
| 2 | **Whole owned library ranked by compatibility** | **Done** | "All my games" tab and `stirredctl owned`. Owned games come from Steam's own cache files (`packageinfo.vdf` + `appinfo.vdf`): no API key, no network, instant. Store details (DirectX 12, anti-cheat, launchers) are then fetched slowly in the background and cached on disk |
| 3 | **"It doesn't work" diagnosis** with one-click fixes | **Done** | "Diagnose…" in each game's menu (and in Activity) and `stirredctl diagnose <game> [--fix]`. Rules in `Diagnosis.swift`; fixes are saved as personal overrides (`overrides/steam/<id>.json`) merged over the recipe. Next: more rules as new failure patterns appear |
| 4 | **Install from Stirred** with progress | **Done** | Install in "Check a game"; download progress and size on Library cards; Steam closes after the download if Stirred started it. Steam still shows its own "Install" window to accept |
| 5 | **Per-game presets Faster / Balanced / Prettier** | **Done (limited)** | Picker on each card, saved per game; `stirredctl preset <game> [name]`. Only levers Stirred controls and verified: frame queue and V-Sync, background shader compilation, a 60 FPS cap. Not done: the game's *own* graphics options (per-engine config files, e.g. Unreal `Engine.ini`) and a render-resolution lever (Unity's `-screen-width` is overridden by games like Muck) |
| 6 | Detect games with a native Mac version | **Done** | Part of the verdict ("play that one") |
| 7 | Pre-launch tasks in recipes (Warframe launcher update as an "Update" button) | Done (Warframe only) | Recipe `updater` + "Update game" menu item + `stirredctl update <game>`; replaces `Scripts/setup-warframe-launcher.sh`. Generic pre-launch tasks not done |
| 8 | Community recipes + anonymous "report result" | Done (offline part) | Export / import of recipe files with strict validation, imported recipes win over bundled ones. Not done: automatic fetching from a hosted repository, anonymous result reports (need a public repo and a privacy design first) |
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
