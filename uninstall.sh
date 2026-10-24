#!/bin/bash
# Stops and removes the gpud launchd agent.
LABEL="local.gpubuddy.gpud"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
echo "gpud removed."
