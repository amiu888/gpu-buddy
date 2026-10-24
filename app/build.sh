#!/bin/bash
# Builds "GPU Buddy.app" next to this script.
set -euo pipefail
cd "$(dirname "$0")"
APP="GPU Buddy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/GPUBuddy" GPUBuddy.swift -framework SwiftUI -framework AppKit -framework Charts
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>GPU Buddy</string>
  <key>CFBundleDisplayName</key><string>GPU Buddy</string>
  <key>CFBundleIdentifier</key><string>local.gpubuddy.app</string>
  <key>CFBundleExecutable</key><string>GPUBuddy</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $(pwd)/$APP"
