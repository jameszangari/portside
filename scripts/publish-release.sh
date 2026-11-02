#!/bin/bash
# MAINTAINER ONLY: part of Portside's release process. Contributors do not need it.
# Step 2 of a release, after the scripts/release.sh pull request is merged.
# Tags the merged commit on main as vX.Y.Z, builds and notarizes
# Portside-X.Y.Z.dmg from it, pushes only the tag, and creates the GitHub
# release with the .dmg attached.
#
# Usage: scripts/publish-release.sh [--dry-run | --apply]
#   --dry-run  (default) print what would happen, change nothing
#   --apply    tag, build, push the tag, then gh release create with the .dmg
#
# Requires: on main and level with origin/main, a clean tree, gh authenticated,
# Developer ID Application identity, and scripts/setup-notary.sh once.
# Safe to rerun after a failed build. Never pushes a branch or force-pushes.
set -euo pipefail

usage() {
    echo "Usage: scripts/publish-release.sh [--dry-run | --apply]" >&2
    exit 2
}

apply=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) apply=false ;;
        --apply) apply=true ;;
        *) usage ;;
    esac
done

root="$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)"
cd "$root"

version="$(tr -d '[:space:]' < VERSION)"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "publish-release: VERSION must be X.Y.Z, got '$version'" >&2
    exit 1
fi
tag="v$version"
dmg="build/dist/Portside-$version.dmg"
branch="$(git rev-parse --abbrev-ref HEAD)"
head_full="$(git rev-parse HEAD)"
head_short="$(git rev-parse --short HEAD)"

# Unset until the first --apply creates the tag.
tag_commit=""
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    tag_commit="$(git rev-list -n 1 "$tag")"
fi
if [ -n "$tag_commit" ] && [ "$tag_commit" != "$head_full" ]; then
    echo "publish-release: tag $tag exists at $(git rev-parse --short "$tag_commit"), not HEAD ($head_short)." >&2
    echo "Bump the version with scripts/release.sh first." >&2
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "publish-release: gh (GitHub CLI) is required" >&2
    exit 1
fi

remote_url="$(git remote get-url origin 2>/dev/null || true)"
if [ -z "$remote_url" ]; then
    echo "publish-release: no git remote named origin" >&2
    exit 1
fi

# One gh call; fails loud if docs/github-visibility disagrees with GitHub
# (catches a private→public flip before you ship another update).
visibility_line=""
if visibility_out="$(scripts/check-repo-visibility.sh 2>&1)"; then
    visibility_line="$visibility_out"
else
    echo "$visibility_out" >&2
    exit 1
fi

if [ "$apply" = false ]; then
    echo "DRY RUN (nothing will change; pass --apply to publish)"
    echo
    echo "  Branch:   $branch at $head_short"
    if [ -n "$tag_commit" ]; then
        echo "  Tag:      $tag exists at HEAD"
    else
        echo "  Tag:      $tag would be created at HEAD"
    fi
    echo "  Disk img: $dmg (rebuilt and notarized on --apply)"
    echo "  $visibility_line"
    if [ "$branch" != "main" ]; then
        echo "  Branch:   not main, --apply would refuse"
    fi
    if gh release view "$tag" >/dev/null 2>&1; then
        echo "  GitHub:   release $tag already exists (would upload/replace the .dmg asset)"
    else
        echo "  GitHub:   would create release $tag with the notarized .dmg attached"
    fi
    echo
    echo "With --apply it would run:"
    echo "  scripts/check-repo-visibility.sh"
    echo "  git tag -a $tag -m \"Release $tag\""
    echo "  scripts/build-app.sh --notarize"
    echo "  git push origin $tag"
    if gh release view "$tag" >/dev/null 2>&1; then
        echo "  gh release upload $tag $dmg --clobber"
    else
        echo "  gh release create $tag --verify-tag --title \"Portside $tag\" --generate-notes $dmg"
    fi
    exit 0
fi

if [ "$branch" != "main" ]; then
    echo "publish-release: run this from main (on $branch)." >&2
    exit 1
fi
git fetch -q origin main
if [ "$head_full" != "$(git rev-parse origin/main)" ]; then
    echo "publish-release: local main differs from origin/main. Merge the release PR and run git pull." >&2
    exit 1
fi

dirty="$(git status --porcelain)"
if [ -n "$dirty" ]; then
    echo "publish-release: working tree is dirty, commit or stash first:" >&2
    echo "$dirty" >&2
    exit 1
fi

echo "==> $visibility_line"
if [ -z "$tag_commit" ]; then
    echo "==> Tagging $head_short as $tag"
    git tag -a "$tag" -m "Release $tag"
fi
echo "==> Building notarized .dmg (Developer ID + notarytool + staple)"
scripts/build-app.sh --notarize
if [ ! -f "$dmg" ]; then
    echo "publish-release: expected $dmg after build-app --notarize" >&2
    exit 1
fi

echo "==> git push origin $tag"
git push origin "$tag"

if gh release view "$tag" >/dev/null 2>&1; then
    echo "==> GitHub release $tag exists, uploading $dmg"
    gh release upload "$tag" "$dmg" --clobber
else
    echo "==> Creating GitHub release $tag with $dmg"
    gh release create "$tag" --verify-tag --title "Portside $tag" --generate-notes "$dmg"
fi

url="$(gh release view "$tag" --json url -q .url)"
echo "Published $tag with Portside.app: $url"
