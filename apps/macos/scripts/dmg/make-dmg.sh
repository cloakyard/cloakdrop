#!/usr/bin/env bash
# Build the stylised CloakDrop installer DMG — a drag-to-Applications window with an install guide,
# on the branded background rendered by background.swift.
#
# Usage:
#   scripts/dmg/make-dmg.sh <path/to/CloakDrop.app> [output.dmg]
#
# Defaults the output to ~/Desktop/CloakDrop-Installer.dmg. macOS only (hdiutil, Finder, SetFile).
# Iterate on the artwork in background.swift and on the window layout in the AppleScript below.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

APP="${1:-}"
OUT="${2:-$HOME/Desktop/CloakDrop-Installer.dmg}"
VOLNAME="CloakDrop"

if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "usage: $0 <path/to/CloakDrop.app> [output.dmg]" >&2
  exit 1
fi

ICON="$REPO/App/Resources/Assets.xcassets/AboutAppIcon.imageset/about_icon_512.png"
ICNS="$APP/Contents/Resources/AppIcon.icns"

if [[ ! -f "$ICON" ]]; then
  echo "missing DMG masthead icon: $ICON" >&2
  exit 1
fi
if [[ ! -f "$ICNS" ]]; then
  echo "missing app volume icon: $ICNS" >&2
  exit 1
fi
if ! command -v SetFile >/dev/null 2>&1; then
  echo "SetFile is required (install the Xcode command-line tools)" >&2
  exit 1
fi

WORK="$(mktemp -d)"
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
DEV=""
cleanup() {
  [[ -n "$DEV" ]] && hdiutil detach "$DEV" -quiet 2>/dev/null || true
  [[ -d "/Volumes/$VOLNAME" ]] && hdiutil detach "/Volumes/$VOLNAME" -quiet 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "▸ Rendering background art…"
swift "$HERE/background.swift" "$ICON" "$STAGE/.background/background.png"
sips -s dpiWidth 144 -s dpiHeight 144 "$STAGE/.background/background.png" >/dev/null
# Keep a version-controlled preview copy next to the source art.
cp "$STAGE/.background/background.png" "$HERE/background.png"

echo "▸ Staging app, guide, Applications alias…"
ditto "$APP" "$STAGE/CloakDrop.app"
cp "$HERE/ReadMe.txt" "$STAGE/Install Guide.txt"
swift "$HERE/guide-icon.swift" "$STAGE/Install Guide.txt"
SetFile -a E "$STAGE/Install Guide.txt"
ln -s /Applications "$STAGE/Applications"
# The volume icon (.VolumeIcon.icns) is written AFTER the Finder pass, not staged here — Finder's
# window management deletes hidden root files it doesn't manage, so a staged copy never survives.

echo "▸ Creating writable DMG…"
RW="$WORK/rw.dmg"
SIZE_MB=$(( $(du -sk "$STAGE" | awk '{print $1}') / 1024 + 40 ))
hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ \
  -format UDRW -size "${SIZE_MB}m" -ov "$RW" >/dev/null

echo "▸ Mounting…"
DEV="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -E '^/dev/' | sed 1q | awk '{print $1}')"
MNT="/Volumes/$VOLNAME"
sleep 1

# Mark support resources invisible without assigning them icon coordinates. Finder includes even
# invisible off-canvas coordinates in its scrollable extent, so hidden files must remain unplaced.
SetFile -a V "$MNT/.background"
if [[ -d "$MNT/.fseventsd" ]]; then
  SetFile -a V "$MNT/.fseventsd" || true
fi

echo "▸ Laying out the window…"
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- 760x570 content + 32pt Tahoe title bar
    set the bounds of container window to {240, 110, 1000, 712}
    set theView to the icon view options of container window
    set arrangement of theView to not arranged
    set icon size of theView to 96
    set text size of theView to 12
    set shows icon preview of theView to false
    set background picture of theView to file ".background:background.png"
    set position of item "CloakDrop.app" of container window to {204, 282}
    set position of item "Applications" of container window to {556, 282}
    set position of item "Install Guide.txt" of container window to {380, 464}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

# Write and hide the volume icon after Finder's layout pass. Adding it earlier can make Finder remove
# the file or clear the custom-volume-icon bit while it updates the window.
cp "$ICNS" "$MNT/.VolumeIcon.icns"
SetFile -a V "$MNT/.background"
if [[ -d "$MNT/.fseventsd" ]]; then
  SetFile -a V "$MNT/.fseventsd" || true
fi
SetFile -a V "$MNT/.VolumeIcon.icns"
SetFile -a C "$MNT"
sync
echo "▸ Detaching…"
hdiutil detach "$DEV" -quiet
DEV=""

echo "▸ Compressing to read-only…"
rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$OUT" >/dev/null

echo "✓ Built $OUT ($(du -h "$OUT" | awk '{print $1}'))"
