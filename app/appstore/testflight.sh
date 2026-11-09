#!/bin/bash
# Archive the Mac App Store edition of GPU Buddy and upload it to App Store Connect (TestFlight).
#   app/appstore/testflight.sh [BUILD_NUMBER] [export|upload]    defaults: 1, upload
# Same bundle ID as the iPhone/iPad app (com.miulabs.gpubuddy): the macOS platform must first be added to the
# existing GPU Buddy app record in App Store Connect. Signing is automatic through the Apple ID in Xcode (team
# XC9C9QZ6W8). Everything goes to dist/appstore-mac/; after a successful upload the archive, the exported
# package and the build folder are deleted (only logs stay), so no stray .app copies are left behind.
set -euo pipefail
cd "$(dirname "$0")"
BUILD="${1:-1}"
MODE="${2:-upload}"
VERSION="$(sed -n 's/^VERSION = "\(.*\)"/\1/p' ../../daemon/gpud.py)"
OUT="../../dist/appstore-mac"
mkdir -p "$OUT"
sed -i '' -e "s/MARKETING_VERSION: .*/MARKETING_VERSION: \"$VERSION\"/" -e "s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
xcodegen generate --spec project.yml >/dev/null
DD="$OUT/DerivedData"
rm -rf "$OUT/GPUBuddy.xcarchive" "$OUT/export" "$OUT/upload" "$DD"
xcodebuild -project GPUBuddyMac.xcodeproj -scheme GPUBuddy -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$DD" -archivePath "$OUT/GPUBuddy.xcarchive" -allowProvisioningUpdates archive > "$OUT/archive.log" 2>&1 \
    || { grep -E "error:" "$OUT/archive.log" >&2; exit 1; }
sed "s#<string>export</string>#<string>$MODE</string>#" ExportOptions.plist > "$OUT/ExportOptions-$MODE.plist"
xcodebuild -exportArchive -archivePath "$OUT/GPUBuddy.xcarchive" -exportOptionsPlist "$OUT/ExportOptions-$MODE.plist" \
    -exportPath "$OUT/$MODE" -allowProvisioningUpdates > "$OUT/$MODE.log" 2>&1 \
    || { grep -E "error:" "$OUT/$MODE.log" >&2; echo "If it says the app or platform is missing, add the macOS platform to the GPU Buddy app record in App Store Connect first." >&2; exit 1; }
rm -rf "$OUT/GPUBuddy.xcarchive" "$DD"
[ "$MODE" = upload ] && rm -rf "$OUT/upload"
echo "Done ($MODE) GPU Buddy for Mac $VERSION ($BUILD). After an upload it shows in App Store Connect → TestFlight (macOS) once processed."
