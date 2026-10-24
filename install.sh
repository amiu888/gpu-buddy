#!/bin/bash
# Installs gpud as a launchd agent (starts at login, restarts if it dies) and builds GPU Buddy.app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
LABEL="local.gpubuddy.gpud"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PORT="${GPUD_PORT:-8765}"

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/python3</string><string>$ROOT/daemon/gpud.py</string>
    <string>--port</string><string>$PORT</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/gpud.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/gpud.log</string>
</dict></plist>
PLIST

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "gpud installed: http://127.0.0.1:$PORT/api/v1/status (logs: ~/Library/Logs/gpud.log)"

"$ROOT/app/build.sh"
sleep 2
echo "Pairing code for watching this Mac from another one (GPU Buddy → Macs):"
/usr/bin/python3 "$ROOT/daemon/gpud.py" --pairing-code || true
echo "Open it with:  open \"$ROOT/app/GPU Buddy.app\""
