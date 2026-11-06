#!/bin/bash
# Archive GPU Buddy for iPhone/iPad and upload it to App Store Connect (TestFlight).
#   ./testflight.sh [BUILD_NUMBER]    default 1; each upload of the same version needs a higher number
# Signing is automatic through the Apple ID signed in to Xcode (team XC9C9QZ6W8).
set -euo pipefail
cd "$(dirname "$0")"
BUILD="${1:-1}"
VERSION="$(sed -n 's/^VERSION = "\(.*\)"/\1/p' ../../../daemon/gpud.py)"
OUT="../../../dist/testflight"
mkdir -p "$OUT"
sed -i '' -e "s/MARKETING_VERSION: .*/MARKETING_VERSION: \"$VERSION\"/" -e "s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
xcodegen generate --spec project.yml >/dev/null
rm -rf "$OUT/GPUBuddy.xcarchive" "$OUT/upload"
xcodebuild -project GPUBuddyiOS.xcodeproj -scheme GPUBuddy -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$OUT/GPUBuddy.xcarchive" -allowProvisioningUpdates archive > "$OUT/archive.log" 2>&1 \
    || { grep -E "error:" "$OUT/archive.log" >&2; exit 1; }
sed 's#<string>export</string>#<string>upload</string>#' ExportOptions.plist > "$OUT/ExportOptions-upload.plist"
xcodebuild -exportArchive -archivePath "$OUT/GPUBuddy.xcarchive" -exportOptionsPlist "$OUT/ExportOptions-upload.plist" \
    -exportPath "$OUT/upload" -allowProvisioningUpdates > "$OUT/upload.log" 2>&1 \
    || { grep -E "error:" "$OUT/upload.log" >&2; echo "If it says the app is missing, create the app record in App Store Connect first (bundle ID com.miulabs.gpubuddy)." >&2; exit 1; }
echo "Uploaded GPU Buddy $VERSION ($BUILD). It shows in App Store Connect → TestFlight after processing (about 5–30 min)."
