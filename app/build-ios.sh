#!/bin/bash
# Builds GPU Buddy for iPhone and iPad from the same Swift code as the Mac app.
#
#   ./build-ios.sh sim              build for the iOS Simulator and install it on the booted simulator
#   ./build-ios.sh device [UDID]    build, sign with your Apple Development certificate, install on a device
#                                   (the first connected iPhone/iPad when no UDID is given)
#
# Signing uses your "Apple Development" certificate and a matching development provisioning profile
# from Xcode (a wildcard team profile works). Override with GPUBUDDY_TEAM, GPUBUDDY_IDENTITY,
# GPUBUDDY_PROFILE, GPUBUDDY_BUNDLE_ID or GPUBUDDY_BUILD_NUMBER (CFBundleVersion).
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-sim}"
VERSION="$(sed -n 's/^VERSION = "\(.*\)"/\1/p' ../daemon/gpud.py)"
# CFBundleVersion: each TestFlight/App Store upload needs a new, higher build number.
BUILD="${GPUBUDDY_BUILD_NUMBER:-$VERSION}"
BUNDLE_ID="${GPUBUDDY_BUNDLE_ID:-local.gpubuddy.ios}"
OUT="build-ios/$MODE"
APP="$OUT/GPU Buddy.app"

case "$MODE" in
    sim) SDK=iphonesimulator; TARGET=arm64-apple-ios17.0-simulator ;;
    device) SDK=iphoneos; TARGET=arm64-apple-ios17.0 ;;
    *) echo "usage: $0 sim | device [UDID]" >&2; exit 2 ;;
esac

rm -rf "$APP"
mkdir -p "$APP"
xcrun -sdk "$SDK" swiftc -O -swift-version 5 -target "$TARGET" -o "$APP/GPUBuddy" GPUBuddy.swift ios/GPUBuddyApp.swift

# App icon: Chippy, rendered by the Mac app.
[ -x "GPU Buddy.app/Contents/MacOS/GPUBuddy" ] || ./build.sh >/dev/null
ASSETS="$OUT/Assets.xcassets"
rm -rf "$ASSETS"
mkdir -p "$ASSETS/AppIcon.appiconset"
"GPU Buddy.app/Contents/MacOS/GPUBuddy" --render-icon "$ASSETS/AppIcon.appiconset/icon.png"
# iOS draws its own rounded corners, so fill the corners the Mac icon leaves transparent.
sips -s format jpeg "$ASSETS/AppIcon.appiconset/icon.png" --out "$OUT/icon.jpg" >/dev/null
sips -s format png "$OUT/icon.jpg" --out "$ASSETS/AppIcon.appiconset/icon.png" >/dev/null
cat > "$ASSETS/AppIcon.appiconset/Contents.json" <<'JSON'
{"images": [{"filename": "icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
 "info": {"author": "xcode", "version": 1}}
JSON
echo '{"info": {"author": "xcode", "version": 1}}' > "$ASSETS/Contents.json"
xcrun actool "$ASSETS" --compile "$APP" --platform "$SDK" --minimum-deployment-target 17.0 \
    --app-icon AppIcon --target-device iphone --target-device ipad \
    --output-partial-info-plist "$OUT/icon-info.plist" >/dev/null

cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>GPU Buddy</string>
  <key>CFBundleDisplayName</key><string>GPU Buddy</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>GPUBuddy</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$([ "$SDK" = iphoneos ] && echo iPhoneOS || echo iPhoneSimulator)</string></array>
  <key>MinimumOSVersion</key><string>17.0</string>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>UILaunchScreen</key><dict><key>UIColorName</key><string></string></dict>
  <key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
  <key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string></array>
  <key>UISupportedInterfaceOrientations~ipad</key><array>
    <string>UIInterfaceOrientationPortrait</string><string>UIInterfaceOrientationPortraitUpsideDown</string>
    <string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string>
  </array>
  <key>UIUserInterfaceStyle</key><string>Dark</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>NSLocalNetworkUsageDescription</key><string>GPU Buddy finds the Macs on your network that run gpud, to show their GPUs.</string>
  <key>NSBonjourServices</key><array><string>_gpubuddy._tcp</string></array>
  <key>NSPhotoLibraryUsageDescription</key><string>Pick a photo to turn into an animated character.</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Merge $OUT/icon-info.plist" "$APP/Info.plist" >/dev/null
printf 'APPL????' > "$APP/PkgInfo"

if [ "$MODE" = sim ]; then
    codesign --force --sign - "$APP" >/dev/null
    xcrun simctl install booted "$APP"
    echo "Installed on the booted simulator: $APP"
    exit 0
fi

# --- Device: sign with your development certificate and a matching profile.
# The valid certificate's SHA-1, so an expired one with the same name doesn't make codesign ambiguous.
IDENTITY="${GPUBUDDY_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
[ -n "$IDENTITY" ] || { echo "No Apple Development certificate found. Sign in to Xcode with your Apple ID first." >&2; exit 1; }
NAME="$(security find-identity -v -p codesigning | awk -v h="$IDENTITY" '$2 == h {sub(/^[^"]*"/, ""); sub(/"$/, ""); print; exit}')"
TEAM="${GPUBUDDY_TEAM:-$(security find-certificate -a -Z -c "$NAME" -p | awk -v h="$IDENTITY" '
    /^SHA-1 hash:/ {keep = ($3 == h)} keep' | openssl x509 -noout -subject | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p')}"
PROFILE="${GPUBUDDY_PROFILE:-}"
if [ -z "$PROFILE" ]; then
    for f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision \
             "$HOME/Library/MobileDevice/Provisioning Profiles"/*.mobileprovision; do
        [ -f "$f" ] || continue
        appid="$(security cms -D -i "$f" 2>/dev/null | plutil -extract Entitlements.application-identifier raw - 2>/dev/null || true)"
        if [ "$appid" = "$TEAM.$BUNDLE_ID" ] || [ "$appid" = "$TEAM.*" ]; then PROFILE="$f"; break; fi
    done
fi
[ -n "$PROFILE" ] || { echo "No development profile for $TEAM.$BUNDLE_ID. Create one in Xcode (any app with automatic signing makes a wildcard one)." >&2; exit 1; }
cp "$PROFILE" "$APP/embedded.mobileprovision"
cat > "$OUT/entitlements.plist" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>application-identifier</key><string>$TEAM.$BUNDLE_ID</string>
  <key>com.apple.developer.team-identifier</key><string>$TEAM</string>
  <key>get-task-allow</key><true/>
</dict></plist>
ENT
codesign --force --sign "$IDENTITY" --entitlements "$OUT/entitlements.plist" "$APP"
echo "Signed with $NAME (team $TEAM)"

DEVICE="${2:-}"
if [ -z "$DEVICE" ]; then
    xcrun devicectl list devices --json-output "$OUT/devices.json" >/dev/null 2>&1 || true
    # Any paired device that's reachable over USB or Wi-Fi, iPhones first.
    DEVICE="$(/usr/bin/python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))["result"]["devices"]
ok = [x for x in d if x["connectionProperties"].get("pairingState") == "paired" and x["connectionProperties"].get("transportType")]
ok.sort(key=lambda x: "iPhone" not in x["hardwareProperties"].get("marketingName", x["deviceProperties"]["name"]))
print(ok[0]["identifier"] if ok else "")' "$OUT/devices.json" 2>/dev/null || true)"
fi
if [ -z "$DEVICE" ]; then
    echo "Built $APP, but no iPhone or iPad is connected. Unlock it, connect it (USB or the same Wi-Fi), then run: $0 device"
    exit 0
fi
if ! xcrun devicectl device install app --device "$DEVICE" "$APP" > "$OUT/install.log" 2>&1; then
    grep -q DeviceLocked "$OUT/install.log" && echo "The device is locked. Unlock it and run: $0 device" >&2 || cat "$OUT/install.log" >&2
    exit 1
fi
echo "Installed GPU Buddy on $DEVICE."
echo "First launch: allow Local Network access when asked, then pair a Mac in the Macs tab."
