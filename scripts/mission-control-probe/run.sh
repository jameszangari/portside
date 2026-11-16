#!/bin/bash
set -euo pipefail
probe_dir="$(cd "$(dirname "$0")" && pwd)"
source "$probe_dir/../swift-env.sh"
swift build --package-path "$probe_dir"
probe_bin="$(swift build --package-path "$probe_dir" --show-bin-path)"
exec "$probe_bin/MissionControlProbe" "$@"
