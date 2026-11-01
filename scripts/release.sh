#!/bin/bash
# Cuts a release: bumps VERSION, regenerates BuildInfo.swift, makes one
# commit "Release vX.Y.Z", creates an annotated tag vX.Y.Z, and builds a
# notarized build/dist/Portside-X.Y.Z.dmg (Developer ID Portside.app).
# Never pushes.
#
# Usage: scripts/release.sh patch|minor|major [--dry-run | --apply]
#   --dry-run  (default) print what would happen, change nothing
#   --apply    actually bump, commit, tag, and package (refuses on a dirty tree)
#
# Publish afterwards with scripts/publish-release.sh (push + GitHub release).
set -euo pipefail

usage() {
    echo "Usage: scripts/release.sh patch|minor|major [--dry-run | --apply]" >&2
    exit 2
}

bump=""
apply=false
for arg in "$@"; do
    case "$arg" in
        patch|minor|major)
            [ -z "$bump" ] || usage
            bump="$arg" ;;
        --dry-run) apply=false ;;
        --apply) apply=true ;;
        *) usage ;;
    esac
done
[ -n "$bump" ] || usage

root="$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)"
cd "$root"

current="$(tr -d '[:space:]' < VERSION)"
if ! [[ "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "release: VERSION must be X.Y.Z, got '$current'" >&2
    exit 1
fi
major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"; patch="${BASH_REMATCH[3]}"
case "$bump" in
    patch) patch=$((patch + 1)) ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    major) major=$((major + 1)); minor=0; patch=0 ;;
esac
next="$major.$minor.$patch"
tag="v$next"
dmg="build/dist/Portside-$next.dmg"
branch="$(git rev-parse --abbrev-ref HEAD)"
head="$(git rev-parse --short HEAD)"

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "release: tag $tag already exists" >&2
    exit 1
fi

dirty="$(git status --porcelain)"

# Developer ID + notary must exist before --apply commits a tag we cannot easily undo.
preflight_signing() {
    if ! security find-identity -v -p codesigning | grep -q 'Developer ID Application:'; then
        echo "release: install a Developer ID Application certificate before --apply." >&2
        exit 1
    fi
    if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE:-portside-notary}" >/dev/null 2>&1; then
        echo "release: run scripts/setup-notary.sh once before --apply." >&2
        exit 1
    fi
}

if [ "$apply" = false ]; then
    echo "DRY RUN (nothing will change; pass --apply to release)"
    echo
    echo "  Branch:   $branch at $head"
    echo "  Version:  $current -> $next ($bump)"
    echo "  Tag:      $tag (annotated)"
    echo "  Disk img: $dmg (notarized Portside.app inside)"
    if [ -n "$dirty" ]; then
        echo "  Tree:     DIRTY, --apply would refuse. Uncommitted changes:"
        echo "$dirty" | sed 's/^/              /'
    else
        echo "  Tree:     clean"
    fi
    echo
    echo "With --apply it would run:"
    echo "  echo $next > VERSION"
    echo "  scripts/gen-version.sh --release"
    echo "  git add VERSION Sources/portside/BuildInfo.swift"
    echo "  git commit -m \"Release $tag\""
    echo "  git tag -a $tag -m \"Release $tag\""
    echo "  scripts/build-app.sh --notarize"
    echo
    echo "It never pushes. Afterwards you would run:"
else
    if [ -n "$dirty" ]; then
        echo "release: working tree is dirty, commit or stash first:" >&2
        echo "$dirty" >&2
        exit 1
    fi
    preflight_signing
    echo "$next" > VERSION
    scripts/gen-version.sh --release
    git add VERSION Sources/portside/BuildInfo.swift
    git commit -q -m "Release $tag"
    git tag -a "$tag" -m "Release $tag"
    echo "Committed \"Release $tag\" ($(git rev-parse --short HEAD)) on $branch and tagged $tag."
    echo "==> Building notarized .dmg for $tag"
    scripts/build-app.sh --notarize
    if [ ! -f "$dmg" ]; then
        echo "release: expected $dmg after build-app --notarize" >&2
        exit 1
    fi
    echo "Nothing was pushed. To publish, run:"
fi

echo "  scripts/publish-release.sh --apply"
echo "  # or manually:"
echo "  git push"
echo "  git push origin $tag"
echo "  gh release create $tag --verify-tag --title \"Portside $tag\" --generate-notes \"$dmg\""
