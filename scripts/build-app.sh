#!/bin/bash
# Builds build/Portside.app from a release build, and refreshes the
# gitignored Portside.app at the repo root with the same bundle.
# Usage: scripts/build-app.sh [--install] [--package] [--notarize]
#   --install   also copy the app to ~/Applications/Portside.app. Refuses
#               while that copy is running. Never touches /Applications.
#   --package   also write build/dist/Portside-X.Y.Z.dmg: a drag-to-install
#               disk image (app, arrow, Applications shortcut) made by
#               scripts/make-dmg.sh. The .dmg is unsigned in this mode.
#   --notarize  sign with Developer ID Application (hardened runtime +
#               timestamp), notarize and staple the app, then build the
#               .dmg, sign it, notarize and staple it too. Implies
#               --package. Needs network and scripts/setup-notary.sh once.
#               Local daily builds stay on the Portside Local Development
#               identity.
# Signing (without --notarize): run scripts/setup-signing.sh once for a
# stable local identity. SIGN_IDENTITY overrides it; SIGN_IDENTITY=- uses
# ad-hoc signing. `swift build` and `swift run portside` are unaffected.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=swift-env.sh
. "$(dirname "$0")/swift-env.sh"
cd "$root"

install=false
package=false
notarize=false
for arg in "$@"; do
    case "$arg" in
        --install) install=true ;;
        --package) package=true ;;
        --notarize) notarize=true; package=true ;;
        *) echo "build-app: unknown argument: $arg" >&2
           echo "Usage: scripts/build-app.sh [--install] [--package] [--notarize]" >&2
           exit 2 ;;
    esac
done

notary_profile="${NOTARY_PROFILE:-portside-notary}"
entitlements="$root/Portside.entitlements"
developer_id_name=""

resolve_developer_id() {
    # Prefer an explicit SIGN_IDENTITY if it is a Developer ID Application.
    if [ -n "${SIGN_IDENTITY:-}" ] && [ "${SIGN_IDENTITY}" != "-" ]; then
        if security find-identity -v -p codesigning | grep -F "$SIGN_IDENTITY" | grep -q "Developer ID Application:"; then
            identity="$SIGN_IDENTITY"
            developer_id_name="$(security find-identity -v -p codesigning | grep -F "$SIGN_IDENTITY" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
            return 0
        fi
    fi
    local line
    line="$(security find-identity -v -p codesigning | grep 'Developer ID Application:' | head -1 || true)"
    if [ -z "$line" ]; then
        echo "build-app: no valid Developer ID Application identity. Install the cert and the G2 intermediate (http://certs.apple.com/devidg2.der)." >&2
        exit 1
    fi
    identity="$(echo "$line" | awk '{print $2}')"
    developer_id_name="$(echo "$line" | sed -E 's/.*"([^"]+)".*/\1/')"
}

identity="${SIGN_IDENTITY:-}"
if [ "$notarize" = true ]; then
    resolve_developer_id
elif [ -z "$identity" ]; then
    identity_file="$HOME/Library/Application Support/com.james.portside/signing/identity.sha1"
    if [ ! -f "$identity_file" ]; then
        echo "build-app: run scripts/setup-signing.sh once to preserve macOS permissions across rebuilds." >&2
        echo "Or set SIGN_IDENTITY to your code signing identity (SIGN_IDENTITY=- opts into ad-hoc signing)." >&2
        exit 1
    fi
    identity="$(tr -d '[:space:]' < "$identity_file")"
    if ! [[ "$identity" =~ ^[[:xdigit:]]{40}$ ]]; then
        echo "build-app: invalid saved signing identity. Run scripts/setup-signing.sh." >&2
        exit 1
    fi
    if ! security find-identity -v -p codesigning | grep -Fq "$identity"; then
        echo "build-app: the saved signing identity is unavailable. Unlock your keychain and run scripts/setup-signing.sh." >&2
        exit 1
    fi
fi

if [ "$notarize" = true ]; then
    if ! xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1; then
        echo "build-app: notary profile '$notary_profile' missing. Run scripts/setup-notary.sh once." >&2
        exit 1
    fi
    if [ ! -f "$entitlements" ]; then
        echo "build-app: missing $entitlements" >&2
        exit 1
    fi
fi

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

# SPM resource bundle (brand PNGs from Sources/portside/Support). It goes
# in Contents/Resources so the code signature covers it; BrandAssets.swift
# looks there.
for bundle in "$bin_dir"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$contents/Resources/"
done

# Info.plist: start from the repo's Info.plist (one source for the
# Calendar and Finder Automation usage strings), then set the bundle keys.
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
set_key LSMinimumSystemVersion string 26.0
set_key LSUIElement bool true
set_key NSHighResolutionCapable bool true
plutil -lint "$plist"

# App icon, best first:
# 1. design/icon-composer/AppIcon.icon compiled by actool: Assets.car
#    (Liquid Glass on macOS 26 and later, CFBundleIconName) plus a flat
#    AppIcon.icns for older macOS.
# 2. The approved brand .icns, copied as is.
# 3. An icon rendered with the hidden `portside --export-icon` flag.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
icon_doc="$root/design/icon-composer/AppIcon.icon"
brand_icns="$root/design/approved-icon/icns/portside-approved-original.icns"
compiled=false
if [ -d "$icon_doc" ]; then
    echo "==> actool AppIcon.icon"
    mkdir "$work/actool"
    if xcrun actool "$icon_doc" --compile "$work/actool" \
            --platform macosx --minimum-deployment-target 26.0 \
            --app-icon AppIcon --include-all-app-icons \
            --output-partial-info-plist "$work/actool.plist" \
            --output-format human-readable-text --errors --warnings >"$work/actool.log" 2>&1 \
        && ! grep -q "error:" "$work/actool.log" \
        && [ -f "$work/actool/Assets.car" ] && [ -f "$work/actool/AppIcon.icns" ]; then
        cp "$work/actool/Assets.car" "$work/actool/AppIcon.icns" "$contents/Resources/"
        set_key CFBundleIconName string AppIcon
        compiled=true
    else
        echo "build-app: actool could not compile AppIcon.icon, using the .icns instead:" >&2
        cat "$work/actool.log" >&2
    fi
fi
if [ "$compiled" = true ]; then
    :
elif [ -f "$brand_icns" ]; then
    echo "==> AppIcon.icns (design)"
    cp "$brand_icns" "$contents/Resources/AppIcon.icns"
else
    echo "==> AppIcon.icns (brand icons missing, generating with --export-icon)" >&2
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
fi
plutil -lint "$plist" >/dev/null

sign_app() {
    local sign_identity="$1"
    if [ "$sign_identity" = "-" ]; then
        echo "==> Signing ad-hoc"
        echo "build-app: ad-hoc builds may ask for macOS permissions again after a rebuild." >&2
        codesign --force --deep --sign "-" "$app"
    elif [ "$notarize" = true ]; then
        echo "==> Signing with Developer ID ($developer_id_name), hardened runtime + timestamp"
        # Nested bundles first, then the app. --deep is not enough for notarization
        # when entitlements must apply to the main executable.
        if [ -d "$contents/Resources" ]; then
            find "$contents/Resources" -name "*.bundle" -type d | while read -r bundle; do
                codesign --force --options runtime --timestamp --sign "$sign_identity" "$bundle"
            done
        fi
        codesign --force --options runtime --timestamp \
            --entitlements "$entitlements" \
            --sign "$sign_identity" "$app"
    else
        # Widen the local key partition list before codesign so macOS does not
        # keep asking for the login password. Dev identity only.
        "$root/scripts/ensure-codesign-key-access.sh"
        echo "==> Signing with '$sign_identity'"
        codesign --force --deep --sign "$sign_identity" "$app"
    fi
    codesign --verify --deep --strict "$app"
}

sign_app "$identity"
echo "Built $app ($version)"

# Submits a file to the Apple notary service and waits. Exits on rejection.
notarize_file() {
    local file="$1"
    local submit_log="$work/notary-$(basename "$file").log"
    echo "==> Notarizing $(basename "$file") (profile $notary_profile)"
    if ! xcrun notarytool submit "$file" \
            --keychain-profile "$notary_profile" \
            --wait --timeout 30m 2>&1 | tee "$submit_log" \
        || ! grep -q "status: Accepted" "$submit_log"; then
        echo "build-app: notarization of $(basename "$file") failed." >&2
        local submission_id
        submission_id="$(grep -Eo 'id: [0-9a-f-]+' "$submit_log" | head -1 | awk '{print $2}' || true)"
        if [ -n "$submission_id" ]; then
            xcrun notarytool log "$submission_id" --keychain-profile "$notary_profile" >&2 || true
        fi
        exit 1
    fi
}

# Apple's ticket CDN often lags a few seconds after "Accepted".
staple_with_retry() {
    local target="$1"
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if xcrun stapler staple "$target"; then
            xcrun stapler validate "$target"
            return 0
        fi
        echo "build-app: staple attempt $attempt failed (ticket may not be published yet), retrying in 15s..."
        sleep 15
    done
    echo "build-app: stapler could not attach the ticket to $target after retries." >&2
    exit 1
}

# Mounts the finished image read-only off /Volumes and checks the app inside.
verify_dmg() {
    local mnt="$work/verify-mount"
    mkdir -p "$mnt"
    hdiutil attach -quiet -readonly -noverify -noautoopen -nobrowse -mountpoint "$mnt" "$dmg"
    local ok=true
    codesign --verify --deep --strict "$mnt/Portside.app" || ok=false
    [ -L "$mnt/Applications" ] || { echo "build-app: Applications link missing in $dmg" >&2; ok=false; }
    [ -f "$mnt/.DS_Store" ] || { echo "build-app: window layout missing in $dmg" >&2; ok=false; }
    if [ "$notarize" = true ]; then
        xcrun stapler validate "$mnt/Portside.app" >/dev/null || ok=false
    fi
    hdiutil detach "$mnt" -quiet
    [ "$ok" = true ] || exit 1
}

dmg="$root/build/dist/Portside-$version.dmg"

if [ "$notarize" = true ]; then
    # The app gets its own ticket so a copy dragged to /Applications still
    # passes Gatekeeper offline. notarytool needs a zip for a bare .app.
    app_zip="$work/Portside-app.zip"
    ditto -c -k --keepParent "$app" "$app_zip"
    notarize_file "$app_zip"
    staple_with_retry "$app"
    spctl --assess --type execute "$app" || { echo "build-app: spctl rejected the stapled app." >&2; exit 1; }
    "$root/scripts/make-dmg.sh" "$app" "$dmg" "$identity"
    notarize_file "$dmg"
    staple_with_retry "$dmg"
    verify_dmg
    echo "==> Gatekeeper assess"
    if ! spctl --assess --type open --context context:primary-signature -vv "$dmg" 2>&1; then
        echo "build-app: spctl rejected the notarized .dmg." >&2
        exit 1
    fi
    echo "Packaged $dmg (notarized)"
elif [ "$package" = true ]; then
    "$root/scripts/make-dmg.sh" "$app" "$dmg"
    verify_dmg
    echo "Packaged $dmg"
fi

# The repo root always holds a copy of the latest build (gitignored). After
# --notarize it is the stapled release app. Swapped with renames so a failed
# copy never leaves the root without an app.
root_app="$root/Portside.app"
root_tmp="$root/.Portside.app.new"
root_old="$root/.Portside.app.old"
rm -rf "$root_tmp" "$root_old"
ditto "$app" "$root_tmp"
codesign --verify --deep --strict "$root_tmp"
[ -e "$root_app" ] && mv "$root_app" "$root_old"
mv "$root_tmp" "$root_app"
rm -rf "$root_old"
echo "Updated $root_app ($version)"

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
