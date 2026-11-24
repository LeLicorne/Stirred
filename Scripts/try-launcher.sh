#!/bin/sh
# Trial of another store's Windows client in its own Windows environment (prefixes/<name>), with the standard engine.
# The installers need you: choose a language, accept the publisher's agreement, sign in. Stirred never does that for you.
# Usage: Scripts/try-launcher.sh <battlenet|ea|ubisoft> [install|run|stop]
set -eu
NAME="${1:?usage: try-launcher.sh <battlenet|ea|ubisoft> [install|run|stop]}"; ACTION="${2:-install}"
ROOT="${STIRRED_ROOT:-$HOME/Library/Application Support/Stirred}"
BIN="$ROOT/engines/stirred-wine-11.21/Wine Staging.app/Contents/Resources/wine/bin"
export WINEPREFIX="$ROOT/prefixes/$NAME" WINEDEBUG=-all WINEMSYNC=1
case "$NAME" in
  battlenet) URL="https://downloader.battle.net/download/getInstaller?os=win&installer=Battle.net-Setup.exe"; FILE="Battle.net-Setup.exe"
             EXE="C:\\Program Files (x86)\\Battle.net\\Battle.net Launcher.exe" ;;
  ea)        URL="https://origin-a.akamaihd.net/EA-Desktop-Client-Download/installer-releases/EAappInstaller.exe"; FILE="EAappInstaller.exe"
             EXE="C:\\Program Files\\Electronic Arts\\EA Desktop\\EA Desktop\\EALauncher.exe" ;;
  ubisoft)   URL="https://ubistatic3-a.akamaihd.net/orbit/launcher_installer/UbisoftConnectInstaller.exe"; FILE="UbisoftConnectInstaller.exe"
             EXE="C:\\Program Files (x86)\\Ubisoft\\Ubisoft Game Launcher\\UbisoftConnect.exe" ;;
  *) echo "unknown launcher: $NAME"; exit 2 ;;
esac
LOG="$ROOT/logs/$NAME-client.log"
case "$ACTION" in
  stop) "$BIN/wineserver" -k; echo "stopped"; exit 0 ;;
  install)
    mkdir -p "$WINEPREFIX" "$ROOT/downloads"
    [ -f "$WINEPREFIX/system.reg" ] || arch -x86_64 "$BIN/wine" wineboot -u >/dev/null 2>&1
    # Battle.net's Update Agent hangs (error BLZBNTBTS0000005C) while Wine's location API is enabled.
    [ "$NAME" = battlenet ] && arch -x86_64 "$BIN/wine" reg add 'HKCU\Software\Wine\DllOverrides' /v locationapi /d '' /f >/dev/null 2>&1
    [ -f "$ROOT/downloads/$FILE" ] || curl -fL -o "$ROOT/downloads/$FILE" "$URL"
    echo "Installer window opening: follow it. Then: Scripts/try-launcher.sh $NAME run"
    arch -x86_64 "$BIN/wine" "$ROOT/downloads/$FILE" > "$LOG" 2>&1 ;;
  run)
    echo "Starting the client; its output goes to $LOG"
    arch -x86_64 "$BIN/wine" "$EXE" > "$LOG" 2>&1 ;;
esac
