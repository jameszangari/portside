#!/bin/bash
# Wraps a built Portside.app in a drag-to-install disk image: the app on
# top, an arrow, and an Applications shortcut below (background from
# scripts/DMGBackground.swift). No network.
# Usage: scripts/make-dmg.sh <Portside.app> <out.dmg> [sign-identity]
#   sign-identity  codesign identity for the .dmg itself; omit or "-" to
#                  leave the image unsigned (the app inside keeps its own).
# Finder lays out the window, so the first run may ask to let your
# terminal control Finder (System Settings > Privacy & Security > Automation).
set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    echo "Usage: scripts/make-dmg.sh <Portside.app> <out.dmg> [sign-identity]" >&2
    exit 2
fi
app="$1"
out="$2"
sign_identity="${3:--}"
root="$(cd "$(dirname "$0")/.." && pwd)"
volname="Portside"
mountpoint="/Volumes/$volname"

[ -d "$app" ] || { echo "make-dmg: no app at $app" >&2; exit 1; }
if [ -e "$mountpoint" ]; then
    echo "make-dmg: $mountpoint is already mounted. Eject it and run again." >&2
    exit 1
fi

work="$(mktemp -d)"
attached=false
cleanup() {
    if [ "$attached" = true ]; then
        hdiutil detach "$mountpoint" -quiet -force || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT

echo "==> DMG background"
helper="$root/scripts/.cache/DMGBackground"
if [ ! -x "$helper" ] || [ "$root/scripts/DMGBackground.swift" -nt "$helper" ]; then
    mkdir -p "$root/scripts/.cache"
    swiftc -O -o "$helper" "$root/scripts/DMGBackground.swift"
fi
"$helper" "$work/bg.png" "$work/bg@2x.png"
# One multi-resolution TIFF so the background stays sharp on Retina.
tiffutil -cathidpicheck "$work/bg.png" "$work/bg@2x.png" -out "$work/background.tiff" >/dev/null 2>&1

stage="$work/stage"
mkdir -p "$stage/.background"
ditto "$app" "$stage/Portside.app"
ln -s /Applications "$stage/Applications"
cp "$work/background.tiff" "$stage/.background/background.tiff"

echo "==> hdiutil create (read-write)"
size_mb=$(( $(du -sm "$stage" | awk '{print $1}') + 20 ))
hdiutil create -quiet -srcfolder "$stage" -volname "$volname" -fs HFS+ \
    -format UDRW -size "${size_mb}m" "$work/rw.dmg"
hdiutil attach -quiet -readwrite -noverify -noautoopen \
    -mountpoint "$mountpoint" "$work/rw.dmg"
attached=true

echo "==> Finder window layout"
# Finder takes a moment to notice a freshly attached volume.
for _ in $(seq 1 20); do
    osascript -e "tell application \"Finder\" to exists disk \"$volname\"" 2>/dev/null | grep -q true && break
    sleep 0.5
done
# Positions are icon centers and must match DMGBackground.swift. The window
# is 28pt taller than the 540x560 background to cover the title bar. Finder
# only saves the window bounds after a close and reopen, and offsets icon
# positions set in the same pass that hides the toolbar, so positions are
# set after the first reopen. Hidden items are parked off-window in case
# the viewer shows hidden files.
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$volname"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 740, 708}
        set opts to icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        close
        open
        set position of item "Portside.app" of container window to {270, 150}
        set position of item "Applications" of container window to {270, 415}
        try
            set position of item ".background" of container window to {900, 900}
        end try
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

# Finder writes .DS_Store asynchronously; wait for the final window size.
for _ in $(seq 1 30); do
    grep -aq "{540, 588}" "$mountpoint/.DS_Store" 2>/dev/null && break
    sleep 0.5
done
grep -aq "{540, 588}" "$mountpoint/.DS_Store" 2>/dev/null \
    || { echo "make-dmg: Finder did not save the window layout" >&2; exit 1; }
SetFile -a V "$mountpoint/.background"
# Volume icon goes in last: hdiutil -srcfolder skips it and the layout pass
# above deletes it. A separate short pass parks it off-window.
if [ -f "$app/Contents/Resources/AppIcon.icns" ]; then
    cp "$app/Contents/Resources/AppIcon.icns" "$mountpoint/.VolumeIcon.icns"
    SetFile -a V "$mountpoint/.VolumeIcon.icns"
    SetFile -a C "$mountpoint"
    osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$volname"
        open
        try
            set position of item ".VolumeIcon.icns" of container window to {1000, 900}
        end try
        close
    end tell
end tell
APPLESCRIPT
    sleep 2
    [ -f "$mountpoint/.VolumeIcon.icns" ] || { echo "make-dmg: Finder removed .VolumeIcon.icns" >&2; exit 1; }
fi
rm -rf "$mountpoint/.fseventsd"
chmod -Rf go-w "$mountpoint" || true
sync
hdiutil detach "$mountpoint" -quiet
attached=false

echo "==> hdiutil convert (compressed, read-only)"
mkdir -p "$(dirname "$out")"
rm -f "$out"
hdiutil convert -quiet "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$out"

if [ "$sign_identity" != "-" ]; then
    echo "==> Signing $(basename "$out")"
    codesign --force --timestamp --sign "$sign_identity" "$out"
    codesign --verify --strict "$out"
fi
echo "Made $out"
