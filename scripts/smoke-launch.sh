#!/bin/bash
# Launch smoke test for a built Portside.app: starts it with a throwaway
# home, checks it is still running after a few seconds, quits it with
# SIGTERM and checks it exits cleanly. The settings put the dock on the
# left edge and leave the macOS Dock alone, so com.apple.dock is never
# changed; the script checks that too. Used by CI.
# Usage: scripts/smoke-launch.sh [Portside.app] [seconds]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-$root/build/Portside.app}"
seconds="${2:-10}"
binary="$app/Contents/MacOS/portside"
[ -x "$binary" ] || { echo "smoke-launch: no app at $app" >&2; exit 1; }

home="$(mktemp -d /tmp/portside-smoke.XXXXXX)"
log="$home/portside.log"
pid=""
cleanup() {
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
    rm -rf "$home"
}
trap cleanup EXIT

support="$home/Library/Application Support/com.james.portside"
mkdir -p "$support"
cat > "$support/dock.json" <<'JSON'
{ "edge": "left", "hideNativeDock": false, "nativeDockExplained": true, "entries": [] }
JSON

# Only the keys "Hide the macOS Dock" changes (NativeDock.swift); the Dock
# itself rewrites others, such as recent apps, at any time.
dock_keys() {
    for key in autohide autohide-delay autohide-time-modifier orientation; do
        echo "$key=$(defaults read com.apple.dock "$key" 2>/dev/null || echo unset)"
    done
}
dock_before="$(dock_keys)"

echo "==> Launching $app for $seconds s"
CFFIXED_USER_HOME="$home" PORTSIDE_ALLOW_SECOND_COPY=1 "$binary" >"$log" 2>&1 &
pid=$!
sleep "$seconds"

if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" && status=0 || status=$?
    pid=""
    echo "smoke-launch: Portside exited early (status $status). Output:" >&2
    cat "$log" >&2
    exit 1
fi

echo "==> Quitting with SIGTERM"
kill -TERM "$pid"
status=0
for _ in $(seq 1 100); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "$pid" 2>/dev/null; then
    echo "smoke-launch: Portside did not quit within 10 s of SIGTERM. Output:" >&2
    cat "$log" >&2
    exit 1
fi
wait "$pid" || status=$?
pid=""
if [ "$status" -ne 0 ]; then
    echo "smoke-launch: Portside exited with status $status. Output:" >&2
    cat "$log" >&2
    exit 1
fi

dock_after="$(dock_keys)"
if [ "$dock_before" != "$dock_after" ]; then
    echo "smoke-launch: com.apple.dock changed during the run." >&2
    exit 1
fi
echo "Smoke launch passed"
