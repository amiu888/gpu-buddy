#!/bin/bash
# Builds "GPU Buddy.app", packs it into dist/GPU-Buddy-<version>.dmg, and (with --publish)
# creates a GitHub release with the DMG attached.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(sed -n 's/^VERSION = "\(.*\)"/\1/p' "$ROOT/daemon/gpud.py")"
DMG="$ROOT/dist/GPU-Buddy-$VERSION.dmg"

"$ROOT/app/build.sh"

STAGE="$(mktemp -d)/GPU Buddy"
mkdir -p "$STAGE" "$ROOT/dist"
cp -R "$ROOT/app/GPU Buddy.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me.txt" <<TXT
GPU Buddy $VERSION

1. Drag GPU Buddy into Applications.
2. Open it. The first time, macOS may say it can't check the app for malicious software
   (it isn't notarized by Apple). Open System Settings → Privacy & Security, scroll down,
   and click "Open Anyway" next to GPU Buddy. Then open it again.
3. GPU Buddy offers to install its background service (gpud). Click Install.
   If macOS asks to install the Command Line Developer Tools, click Install too.

Watching other Macs: GPU Buddy menu → Macs… (⌘K).
Source and docs: https://github.com/amiu888/gpu-buddy
TXT
rm -f "$DMG"
hdiutil create -volname "GPU Buddy" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "Packed $DMG ($(du -h "$DMG" | cut -f1))"

if [ "${1:-}" = "--publish" ]; then
    gh release create "v$VERSION" "$DMG" --title "GPU Buddy $VERSION" --notes-file "$ROOT/dist/notes-$VERSION.md"
fi
