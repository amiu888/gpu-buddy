#!/bin/bash
# Builds "GPU Buddy.app" next to this script, with gpud bundled inside so the app can install it.
set -euo pipefail
cd "$(dirname "$0")"
APP="GPU Buddy.app"
VERSION="$(sed -n 's/^VERSION = "\(.*\)"/\1/p' ../daemon/gpud.py)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/daemon"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -o "$APP/Contents/MacOS/GPUBuddy" GPUBuddy.swift \
    -framework SwiftUI -framework AppKit -framework Charts

# The background service: gpud plus a prebuilt power helper, so users need no compiler.
cp ../daemon/gpud.py ../daemon/gpupower.c ../daemon/prices.json "$APP/Contents/Resources/daemon/"
clang -O2 -arch arm64 -mmacosx-version-min=14.0 -o "$APP/Contents/Resources/daemon/gpupower" \
    ../daemon/gpupower.c -framework CoreFoundation -framework IOKit -lIOReport

# Icon: Chippy, drawn by the app itself.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
"$APP/Contents/MacOS/GPUBuddy" --render-icon "$ICONSET/icon_512x512@2x.png"
for size in 16 32 128 256 512; do
    sips -z $size $size "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    [ $double -le 1024 ] && sips -z $double $double "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>GPU Buddy</string>
  <key>CFBundleDisplayName</key><string>GPU Buddy</string>
  <key>CFBundleIdentifier</key><string>local.gpubuddy.app</string>
  <key>CFBundleExecutable</key><string>GPUBuddy</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>NSLocalNetworkUsageDescription</key><string>GPU Buddy finds and shows the GPUs of other Macs on your network.</string>
  <key>NSBonjourServices</key><array><string>_gpubuddy._tcp</string></array>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $(pwd)/$APP ($VERSION)"
