#!/bin/bash
# Window-fit probe: measures how window managers and macOS resize windows
# against the dock edge. Needs Accessibility for the terminal that runs it.
# Usage: scripts/window-fit-probe/run.sh [rect|native|gap|dock|dock2|dock3|fit|all]
# The probe window takes focus for a few seconds. dock* modes toggle the
# macOS Dock's autohide (the Dock flashes on screen); gap mode writes
# Rectangle's screenEdgeGapBottom. Both are restored to their exact prior values.
set -euo pipefail
mode="${1:-all}"
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d /tmp/portside-window-fit.XXXXXX)"
app="$work/Probe.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.james.portside.probe</string>
<key>CFBundleName</key><string>PortsideProbe</string>
<key>CFBundleExecutable</key><string>probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
swiftc -O "$here/ProbeTarget.swift" -o "$app/Contents/MacOS/probe"
swiftc -O "$here/ProbeObserver.swift" -o "$work/observer"

prior_autohide="$(defaults read com.apple.dock autohide 2>/dev/null || echo missing)"
prior_gap="$(defaults read com.knollsoft.Rectangle screenEdgeGapBottom 2>/dev/null || echo missing)"
restore() {
  pkill -f "$app/Contents/MacOS/probe" 2>/dev/null || true
  now_autohide="$(defaults read com.apple.dock autohide 2>/dev/null || echo missing)"
  if [ "$now_autohide" != "$prior_autohide" ]; then
    if [ "$prior_autohide" = missing ]; then defaults delete com.apple.dock autohide; else defaults write com.apple.dock autohide -bool "$prior_autohide"; fi
    killall Dock
    echo "restored com.apple.dock autohide = $prior_autohide"
  fi
  now_gap="$(defaults read com.knollsoft.Rectangle screenEdgeGapBottom 2>/dev/null || echo missing)"
  if [ "$now_gap" != "$prior_gap" ]; then
    if [ "$prior_gap" = missing ]; then defaults delete com.knollsoft.Rectangle screenEdgeGapBottom; else defaults write com.knollsoft.Rectangle screenEdgeGapBottom -int "$prior_gap"; fi
    echo "restored Rectangle screenEdgeGapBottom = $prior_gap"
  fi
}
trap restore EXIT

open -n --stdout "$work/target.log" "$app"
for _ in $(seq 50); do grep -q launch "$work/target.log" 2>/dev/null && break; perl -e 'select(undef,undef,undef,0.1)'; done
"$work/observer" "$mode" | tee "$work/observer.log"
echo "logs: $work"
