#!/usr/bin/env bash
# Installs simlease and its periodic gc agent for the current user.
# Usage: ./install.sh [--prefix DIR] [--no-agent] [--uninstall]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PREFIX="$HOME/.local"
AGENT=true
UNINSTALL=false
LABEL=dev.simlease.gc
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/simlease"

while (( $# )); do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
    --no-agent) AGENT=false; shift ;;
    --uninstall) UNINSTALL=true; shift ;;
    *) echo "usage: ./install.sh [--prefix DIR] [--no-agent] [--uninstall]" >&2; exit 2 ;;
  esac
done

BIN="$PREFIX/bin/simlease"

unload_agent() {
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
}

if [[ "$UNINSTALL" == true ]]; then
  unload_agent
  rm -f "$PLIST" "$BIN"
  echo "removed $BIN and $PLIST; config ($CONFIG_DIR) and state (~/Library/Application Support/simlease) were kept"
  exit 0
fi

command -v jq >/dev/null || { echo "simlease needs jq: brew install jq" >&2; exit 1; }
command -v xcrun >/dev/null || { echo "simlease needs Xcode command line tools" >&2; exit 1; }

mkdir -p "$PREFIX/bin"
install -m 0755 "$ROOT/bin/simlease" "$BIN"
echo "installed $BIN"

mkdir -p "$CONFIG_DIR"
if [[ -f "$CONFIG_DIR/config.json" ]]; then
  echo "kept existing $CONFIG_DIR/config.json"
else
  cp "$ROOT/config.example.json" "$CONFIG_DIR/config.json"
  echo "wrote $CONFIG_DIR/config.json from config.example.json; adjust the pools to your devices"
fi

if [[ "$AGENT" == true ]]; then
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  jq_dir="$(dirname "$(command -v jq)")"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>gc</string>
    </array>
    <key>StartInterval</key>
    <integer>900</integer>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/simlease-gc.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/simlease-gc.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$jq_dir:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
EOF
  unload_agent
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "loaded launchd agent $LABEL (simlease gc every 15 minutes, log ~/Library/Logs/simlease-gc.log)"
fi

case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *) echo "note: $PREFIX/bin is not on PATH" ;;
esac
