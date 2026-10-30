#!/bin/bash
# Builds build/Portside.app from a release build. No network.
# Usage: scripts/build-app.sh [--install]
#   --install  also copy the app to ~/Applications/Portside.app. Refuses
#              while that copy is running. Never touches /Applications.
# Signing: ad-hoc by default. Set SIGN_IDENTITY to a codesigning identity
# (for example a self-signed certificate's name) to sign with it instead.
# `swift build` and `swift run portside` are unaffected by this script.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

install=false
for arg in "$@"; do
    case "$arg" in
        --install) install=true ;;
        *) echo "build-app: unknown argument: $arg" >&2
           echo "Usage: scripts/build-app.sh [--install]" >&2
           exit 2 ;;
    esac
done

version="$(tr -d '[:space:]' < VERSION)"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "build-app: VERSION must be X.Y.Z, got '$version'" >&2
    exit 1
fi

echo "==> swift build -c release"
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
binary="$bin_dir/portside"
[ -x "$binary" ] || { echo "build-app: no binary at $binary" >&2; exit 1; }

app="$root/build/Portside.app"
contents="$app/Contents"
echo "==> Assembling $app"
rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$binary" "$contents/MacOS/portside"

# SPM resource bundles, if a target ever gains real resources.
for bundle in "$bin_dir"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$contents/Resources/"
done

# Info.plist: start from the repo's Info.plist (one source for the
# Calendar usage strings), then set the bundle keys.
plist="$contents/Info.plist"
cp "$root/Info.plist" "$plist"
set_key() { plutil -replace "$1" "-$2" "$3" "$plist"; }
set_key CFBundleExecutable string portside
set_key CFBundleIdentifier string com.james.portside
set_key CFBundleName string Portside
set_key CFBundleDisplayName string Portside
set_key CFBundlePackageType string APPL
set_key CFBundleShortVersionString string "$version"
set_key CFBundleVersion string "$version"
set_key CFBundleIconFile string AppIcon
set_key CFBundleInfoDictionaryVersion string 6.0
set_key LSMinimumSystemVersion string 14.0
set_key LSUIElement bool true
set_key NSHighResolutionCapable bool true
plutil -lint "$plist"

# App icon, drawn by the app itself (AppIcon.swift).
echo "==> AppIcon.icns"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
master="$work/icon_1024.png"
"$contents/MacOS/portside" --export-icon "$master" >/dev/null
iconset="$work/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$master" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$master" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$contents/Resources/AppIcon.icns"

identity="${SIGN_IDENTITY:--}"
if [ "$identity" = "-" ]; then
    echo "==> Signing ad-hoc"
else
    echo "==> Signing with '$identity'"
fi
codesign --force --deep --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
echo "Built $app ($version)"

if [ "$install" = true ]; then
    dest="$HOME/Applications/Portside.app"
    if pgrep -f "$dest/Contents/MacOS/portside" >/dev/null 2>&1; then
        echo "build-app: $dest is running. Quit Portside (menu bar item > Quit Portside) and run again." >&2
        exit 1
    fi
    mkdir -p "$HOME/Applications"
    rm -rf "$dest"
    ditto "$app" "$dest"
    codesign --verify --deep --strict "$dest"
    echo "Installed $dest"
fi
