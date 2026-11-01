#!/bin/bash
# Publishes the current VERSION's annotated tag to GitHub with the notarized
# drag-to-install Portside-X.Y.Z.dmg attached. Always rebuilds and
# notarizes from the tagged commit before uploading.
#
# Usage: scripts/publish-release.sh [--dry-run | --apply]
#   --dry-run  (default) print what would happen, change nothing
#   --apply    push the branch tip and tag, then gh release create with the .dmg
#
# Requires: VERSION is X.Y.Z, tag vX.Y.Z exists locally, gh is authenticated,
# Developer ID Application identity, and scripts/setup-notary.sh once.
# Refuses if the tag does not point at HEAD (run from the release commit).
# Never force-pushes. Does not bump VERSION (use scripts/release.sh for that).
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

if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "publish-release: tag $tag does not exist. Cut it with scripts/release.sh first." >&2
    exit 1
fi

tag_commit="$(git rev-list -n 1 "$tag")"
tag_short="$(git rev-parse --short "$tag_commit")"
head_matches_tag=true
if [ "$tag_commit" != "$head_full" ]; then
    head_matches_tag=false
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
    echo "  Tag:      $tag at $tag_short"
    echo "  Disk img: $dmg (rebuilt and notarized on --apply)"
    echo "  $visibility_line"
    if [ "$head_matches_tag" = false ]; then
        echo "  HEAD:     does not match $tag; --apply would refuse (git checkout $tag)"
    fi
    if gh release view "$tag" >/dev/null 2>&1; then
        echo "  GitHub:   release $tag already exists (would upload/replace the .dmg asset)"
    else
        echo "  GitHub:   would create release $tag with the notarized .dmg attached"
    fi
    echo
    echo "With --apply it would run:"
    echo "  scripts/check-repo-visibility.sh"
    echo "  scripts/build-app.sh --notarize"
    echo "  git push -u origin HEAD"
    echo "  git push origin $tag"
    if gh release view "$tag" >/dev/null 2>&1; then
        echo "  gh release upload $tag $dmg --clobber"
    else
        echo "  gh release create $tag --verify-tag --title \"Portside $tag\" --generate-notes $dmg"
    fi
    exit 0
fi

if [ "$head_matches_tag" = false ]; then
    echo "publish-release: HEAD ($head_short) is not tag $tag ($tag_short)." >&2
    echo "Check out the release commit (git checkout $tag) or cut a new release." >&2
    exit 1
fi

dirty="$(git status --porcelain)"
if [ -n "$dirty" ]; then
    echo "publish-release: working tree is dirty, commit or stash first:" >&2
    echo "$dirty" >&2
    exit 1
fi

echo "==> $visibility_line"
echo "==> Building notarized .dmg (Developer ID + notarytool + staple)"
scripts/build-app.sh --notarize
if [ ! -f "$dmg" ]; then
    echo "publish-release: expected $dmg after build-app --notarize" >&2
    exit 1
fi

echo "==> git push origin HEAD"
git push -u origin HEAD
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
