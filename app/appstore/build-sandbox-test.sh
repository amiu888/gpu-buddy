#!/bin/bash
# Builds "GPU Buddy Sandbox Test.app": the Mac App Store edition, sandboxed exactly like the store build,
# but with its own bundle ID (com.miulabs.gpubuddy.sandboxtest) so its container and settings stay apart
# from the DMG app and the real store app. Signed with Developer ID (hardened runtime + App Sandbox), not
# notarized, nothing installed, uploaded or launched.
#
# Output always goes to one folder, wiped first, and Xcode's build folder is deleted afterwards, so no stray
# .app copies pile up (each one adds a row in System Settings › Privacy & Security › Local Network).
#   GPUBUDDY_TEST_OUT   output folder (default: <repo>/dist/appstore-mac-test)
#   GPUBUDDY_SIGN_IDENTITY   signing identity (default: first Developer ID Application, else ad-hoc)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${GPUBUDDY_TEST_OUT:-$ROOT/dist/appstore-mac-test}"
NAME="GPU Buddy Sandbox Test"
BUNDLE_ID="com.miulabs.gpubuddy.sandboxtest"
case "$(basename "$OUT")" in appstore-mac-test) ;; *) echo "output folder must be named appstore-mac-test: $OUT" >&2; exit 1 ;; esac
IDENTITY="${GPUBUDDY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Developer ID Application:/ {print $2; exit}')}"
[ -n "$IDENTITY" ] || IDENTITY="-"

rm -rf "$OUT"; mkdir -p "$OUT"
cd "$HERE"
xcodegen generate --spec project.yml >/dev/null
DD="$OUT/DerivedData"
echo "==> building (Release, arm64)"
xcodebuild -project GPUBuddyMac.xcodeproj -scheme GPUBuddy -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" build > "$OUT/build.log" 2>&1 \
    || { grep -E "error:" "$OUT/build.log" >&2; exit 1; }
APP="$OUT/$NAME.app"
ditto "$DD/Build/Products/Release/GPU Buddy.app" "$APP"
rm -rf "$DD"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $NAME" -c "Set :CFBundleDisplayName $NAME" "$APP/Contents/Info.plist"
xattr -cr "$APP"
TS="--timestamp"; [ "$IDENTITY" = "-" ] && TS=""
echo "==> signing ($([ "$IDENTITY" = "-" ] && echo ad-hoc || echo "Developer ID ${IDENTITY:0:8}…"), hardened runtime, App Sandbox)"
codesign --force --options runtime $TS --entitlements GPUBuddy-AppStore.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q com.apple.security.app-sandbox || { echo "not sandboxed?!" >&2; exit 1; }
echo "==> done: $APP"
echo "    open it with:  open \"$APP\""
