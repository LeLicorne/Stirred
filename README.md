# Stirred

Play your Windows Steam games on an Apple Silicon Mac, locally (no streaming, no input lag from a server).
Free, open source (GPL-3), built only from open-source components.

> **Status: working prototype.** Several games run well (see below), but it is young software.
> Stirred is not affiliated with Valve, Apple or any game publisher. Steam is a trademark of Valve.

## What you get

- **Library**: your installed Steam games with cover art, a compatibility badge, a latency setting and a **Play** button.
  Stirred starts Steam in the background for you (no window) and **closes it again when your game ends**, along with anything the
  game left behind (launchers, helpers). If you opened Steam yourself (for example to install a game), Stirred leaves it open until you
  press **Quit** in the sidebar. The toolbar switch "Close Steam after playing" turns this behaviour off.
- **Check a game**: type a name or paste a Steam link and get a verdict *before* installing anything
  (tested here, native Mac version, anti-cheat, DirectX 12, Steam Deck status). You can install from there; the download shows on its card.
- **Activity**: every launch is recorded (CPU, GPU, memory, crashes, graphics problems) with a plain-language summary.
- **Logs**: Steam and graphics logs, searchable, with an "errors only" filter.
- **One-time setup** inside the app: it downloads and installs everything it needs (about 300 MB).

## Requirements

- A Mac with **Apple Silicon** (M1 or later), **macOS 14+**, **Rosetta 2** installed
  (`softwareupdate --install-rosetta --agree-to-license`).
- About 2 GB free for Stirred itself, plus room for your games.
- A Steam account. Use a secondary one while you experiment.
- For laptops: **plug in and turn Low Power Mode off**, otherwise games are capped around 30 FPS.

## Install

1. Install Xcode (free) and open it once so the command-line tools are set up.
2. Build the app:
   ```sh
   git clone <this repository> && cd stirred
   Scripts/build-app.sh          # builds build/Stirred.app (add "release" for an optimised build)
   open build/Stirred.app
   ```
   Or pack it: `Scripts/make-dmg.sh` creates `build/Stirred.dmg`.
3. The app is **not notarized** (that needs a paid Apple developer account). If you got it as a download,
   macOS will refuse it the first time: open **System Settings > Privacy & Security** and press **Open Anyway**.
   An app you build yourself opens without any warning.

## First start

1. Press **Set up Stirred**. It installs the Wine engine, the graphics layer, a private Windows environment and Steam.
   Steam updates itself once (a few minutes).
2. A Steam window opens: **sign in once** (tick "remember me" so later starts need no window).
3. Install games from that Steam window (or `stirredctl install <appid>`); they appear in the Library.
   To remove one, use the **…** menu on its card (or right-click it) > **Uninstall…**: Stirred shows how much it will delete, asks to
   confirm, closes Steam, and deletes the game's files. Your Steam Cloud saves are kept. CLI: `stirredctl uninstall <game> --yes`.
4. Press **Play**. Always start games from Stirred, not from Steam's own window: only Stirred applies the graphics fixes.

## Games tested (Apple M4, 16 GB, macOS 27)

| Game | Result |
|---|---|
| Muck | Playable, ~130 FPS on low graphics |
| HoloCure | Playable |
| Warframe | Playable: ~90 FPS on low graphics, ~37 FPS on medium. Needs a one-time launcher update, see [docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md) |
| Trackmania | Does not start (Ubisoft Connect hangs under Wine) |
| For The King II | Playable (needs DirectX 11 forced, which Stirred does automatically for Unity games) |
| Cat Purrtrol: Find All 100! | Crashes at startup (32-bit Unity) |

Games protected by kernel anti-cheat (Easy Anti-Cheat, BattlEye, Vanguard...) cannot run on macOS and Stirred does not
try to work around them. For Counter-Strike 2 the recipe only allows offline play with Valve's `-insecure` switch.

## Command line

`stirredctl` is the same engine without the window, handy for debugging:

```sh
swift build && .build/debug/stirredctl doctor          # what is installed, what is missing
.build/debug/stirredctl setup                          # install everything missing
.build/debug/stirredctl library                        # installed games
.build/debug/stirredctl run muck --watch               # play and record a session (name or appid)
.build/debug/stirredctl report                         # latest session report
```

## Troubleshooting

- **FPS stuck near 30**: Low Power Mode or battery power. Stirred warns about both.
- **Steam window is black or blank**: Stirred installs a small fix for it; run setup again, or see the known issues.
- **A game starts then closes**: open **Activity** for its report, and **Logs** for details.
- More in [docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md).

## For developers

- Architecture and data layout: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Current status and next steps: [docs/PROGRESS.md](docs/PROGRESS.md)
- Third-party components and licenses: [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)
- Tests: `swift test -j 4`. Per-game knowledge lives in `recipes/steam/<appid>.json`.

Never type a Steam password into anything but the Steam window: Stirred never sees your credentials.
