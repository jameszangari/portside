#!/bin/bash
# Writes Sources/portside/BuildInfo.swift from VERSION plus git state.
# Usage: scripts/gen-version.sh [--release]
#   --release  mark the build as a release (used by scripts/release.sh,
#              which runs this right before the release commit).
# Without --release, the build counts as a release only when HEAD carries
# the tag v<VERSION> and the working tree is clean.
# No network. If git is missing or fails, the commit is "unknown".
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/Sources/portside/BuildInfo.swift"
release_flag=false

for arg in "$@"; do
    case "$arg" in
        --release) release_flag=true ;;
        *) echo "gen-version: unknown argument: $arg" >&2; exit 2 ;;
    esac
done

version="$(tr -d '[:space:]' < "$root/VERSION")"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "gen-version: VERSION must be X.Y.Z, got '$version'" >&2
    exit 1
fi

commit="unknown"
dirty="nil"
if command -v git >/dev/null 2>&1 && git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    commit="$(git -C "$root" rev-parse --short HEAD 2>/dev/null)" || commit="unknown"
    [ -n "$commit" ] || commit="unknown"
    # BuildInfo.swift itself is excluded, or regenerating it would mark the next run dirty.
    if status="$(git -C "$root" status --porcelain -- . ':(exclude)Sources/portside/BuildInfo.swift' 2>/dev/null)"; then
        if [ -n "$status" ]; then dirty="true"; else dirty="false"; fi
    fi
fi

is_release=false
if [ "$release_flag" = true ]; then
    is_release=true
elif [ "$commit" != "unknown" ] && [ "$dirty" = "false" ] \
    && git -C "$root" tag --points-at HEAD 2>/dev/null | grep -qx "v$version"; then
    is_release=true
fi

content="// GENERATED FILE. Do not edit by hand.
// Written by scripts/gen-version.sh from VERSION and git state.
// The version number is edited only in VERSION at the repo root.

enum BuildInfo {
    /// Marketing version from VERSION.
    static let version = \"$version\"
    /// Short hash of HEAD when this file was generated, or \"unknown\".
    static let commit = \"$commit\"
    /// Uncommitted changes when generated. nil if git was unavailable.
    static let isDirty: Bool? = $dirty
    /// True for a tagged release build (see scripts/gen-version.sh).
    static let isRelease = $is_release
}
"

# Only rewrite on change so swift build doesn't recompile for nothing.
if [ -f "$out" ] && [ "$(cat "$out")" = "${content%$'\n'}" ]; then
    echo "BuildInfo.swift unchanged: $version ($commit, dirty: $dirty, release: $is_release)"
else
    printf '%s' "$content" > "$out"
    echo "Wrote BuildInfo.swift: $version ($commit, dirty: $dirty, release: $is_release)"
fi
