#!/bin/bash
# Builds "GPU Buddy.app", packs it into dist/GPU-Buddy-<version>.dmg, and (with --publish)
# creates a GitHub release with the DMG attached.
#
# Signing and notarization are optional and come from your own keychain, never from this repo:
#   GPUBUDDY_SIGN_IDENTITY   a "Developer ID Application: …" identity (name or SHA-1). Without it the app is
#                            only ad-hoc signed, and macOS asks people to use "Open Anyway" the first time.
#   GPUBUDDY_NOTARY_PROFILE  a notarytool keychain profile, made once with
#                            `xcrun notarytool store-credentials <name> --apple-id … --team-id …`.
#                            With it, the DMG is notarized by Apple and the ticket is stapled.
#   GPUBUDDY_BUILD_NUMBER    CFBundleVersion (defaults to the version).
#
# --publish needs dist/notes-<version>.md and refuses to reuse an existing tag.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(sed -n 's/^VERSION = "\(.*\)"/\1/p' "$ROOT/daemon/gpud.py")"
DMG="$ROOT/dist/GPU-Buddy-$VERSION.dmg"
NOTES="$ROOT/dist/notes-$VERSION.md"
IDENTITY="${GPUBUDDY_SIGN_IDENTITY:-}"
NOTARY="${GPUBUDDY_NOTARY_PROFILE:-}"
PUBLISH=0
[ "${1:-}" = "--publish" ] && PUBLISH=1

[ -n "$VERSION" ] || { echo "No VERSION in daemon/gpud.py" >&2; exit 1; }
if [ $PUBLISH = 1 ]; then
    [ -f "$NOTES" ] || { echo "Write the release notes first: $NOTES" >&2; exit 1; }
    if git -C "$ROOT" rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null \
        || git -C "$ROOT" ls-remote --exit-code --tags origin "v$VERSION" >/dev/null 2>&1; then
        echo "Tag v$VERSION already exists. Bump VERSION in daemon/gpud.py first." >&2; exit 1
    fi
    [ -n "$IDENTITY" ] && [ -n "$NOTARY" ] || {
        echo "Publishing needs GPUBUDDY_SIGN_IDENTITY and GPUBUDDY_NOTARY_PROFILE (signed and notarized DMG)." >&2; exit 1; }
fi
[ -z "$NOTARY" ] || [ -n "$IDENTITY" ] || { echo "Notarizing needs GPUBUDDY_SIGN_IDENTITY too." >&2; exit 1; }

"$ROOT/app/build.sh"
APP="$ROOT/app/GPU Buddy.app"

if [ -n "$IDENTITY" ]; then
    # Inner code first, then the app, with the hardened runtime and a secure timestamp (both needed for notarization).
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Resources/daemon/gpupower"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
fi

STAGE="$(mktemp -d)/GPU Buddy"
mkdir -p "$STAGE" "$ROOT/dist"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
if [ -n "$NOTARY" ]; then
    OPEN_STEP="2. Open it. It's signed and notarized by Apple, so it opens like any other app."
else
    OPEN_STEP="2. Open it. The first time, macOS may say it can't check the app for malicious software
   (this copy isn't notarized by Apple). Open System Settings → Privacy & Security, scroll down,
   and click \"Open Anyway\" next to GPU Buddy. Then open it again."
fi
cat > "$STAGE/Read Me.txt" <<TXT
GPU Buddy $VERSION

1. Drag GPU Buddy into Applications.
$OPEN_STEP
3. GPU Buddy offers to install its background service (gpud). Click Install.
   If macOS asks to install the Command Line Developer Tools, click Install too.

Watching other Macs: GPU Buddy menu → Macs… (⌘K).
Source and docs: https://github.com/amiu888/gpu-buddy
TXT
rm -f "$DMG"
hdiutil create -volname "GPU Buddy" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

if [ -n "$IDENTITY" ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi
if [ -n "$NOTARY" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi
echo "Packed $DMG ($(du -h "$DMG" | cut -f1))"
echo "SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"

if [ $PUBLISH = 1 ]; then
    gh release create "v$VERSION" "$DMG" --title "GPU Buddy $VERSION" --notes-file "$NOTES"
fi
