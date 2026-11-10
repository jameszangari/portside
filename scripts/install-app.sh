#!/bin/bash
# Development install: macOS 27 only treats a status item as the app's own when
# the app is in /Applications, so menu bar hiding cannot be tested from a build
# folder or `swift run`. Builds the app, signs it with the Developer ID (which
# keeps the existing Accessibility grant) and replaces /Applications/Portside.app.
# Keep a release copy elsewhere first. Usage: scripts/install-app.sh [--no-launch]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
target=/Applications/Portside.app
launch=true
[ "${1:-}" = "--no-launch" ] && launch=false

identity="$(security find-identity -v -p codesigning | grep 'Developer ID Application:' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
[ -n "$identity" ] || { echo "install-app: no Developer ID Application identity" >&2; exit 1; }

"$root/scripts/build-app.sh"
staged="$(mktemp -d)/Portside.app"
ditto "$root/build/Portside.app" "$staged"
codesign --force --options runtime --timestamp=none --sign "$identity" --entitlements "$root/Portside.entitlements" "$staged"
codesign --verify --deep --strict "$staged"

pkill -x portside || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x portside >/dev/null || break; sleep 0.5; done
rm -rf "$target"
ditto "$staged" "$target"
rm -rf "$(dirname "$staged")"
echo "Installed $target $(shasum -a 256 "$target/Contents/MacOS/portside" | cut -c1-16)"
if $launch; then open "$target"; fi
