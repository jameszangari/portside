#!/bin/bash
# MAINTAINER ONLY: part of Portside's release process. Contributors do not need it.
# Step 1 of a release. From an up-to-date main, makes a release/vX.Y.Z branch
# with one "Release vX.Y.Z" commit (VERSION and BuildInfo.swift), pushes the
# branch, and opens a pull request. main is protected, so nothing goes to it
# directly. Does not tag or build.
#
# Usage: scripts/release.sh patch|minor|major [--dry-run | --apply]
#   --dry-run  (default) print what would happen, change nothing
#   --apply    actually bump, commit, push the branch, and open the PR
#
# Step 2, after the PR is merged: scripts/publish-release.sh --apply
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
release_branch="release/$tag"
branch="$(git rev-parse --abbrev-ref HEAD)"
head="$(git rev-parse --short HEAD)"

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "release: tag $tag already exists" >&2
    exit 1
fi

dirty="$(git status --porcelain)"

# Developer ID + notary must exist before opening a PR we could not publish.
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
    echo "  PR:       $release_branch -> main"
    if [ -n "$dirty" ]; then
        echo "  Tree:     DIRTY, --apply would refuse. Uncommitted changes:"
        echo "$dirty" | sed 's/^/              /'
    else
        echo "  Tree:     clean"
    fi
    if [ "$branch" != "main" ]; then
        echo "  Branch:   not main, --apply would refuse"
    fi
    echo
    echo "With --apply it would run:"
    echo "  git switch -c $release_branch"
    echo "  echo $next > VERSION"
    echo "  scripts/gen-version.sh --release"
    echo "  git add VERSION Sources/portside/BuildInfo.swift"
    echo "  git commit -m \"Release $tag\""
    echo "  git push -u origin $release_branch"
    echo "  gh pr create --base main --head $release_branch"
    echo "  git switch main"
    exit 0
fi

if [ -n "$dirty" ]; then
    echo "release: working tree is dirty, commit or stash first:" >&2
    echo "$dirty" >&2
    exit 1
fi
if [ "$branch" != "main" ]; then
    echo "release: run this from main (on $branch)." >&2
    exit 1
fi
git fetch -q origin main
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
    echo "release: local main differs from origin/main. Run git pull first." >&2
    exit 1
fi
if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
    echo "release: tag $tag already exists on origin" >&2
    exit 1
fi
preflight_signing

git switch -q -c "$release_branch"
echo "$next" > VERSION
scripts/gen-version.sh --release
git add VERSION Sources/portside/BuildInfo.swift
git commit -q -m "Release $tag"
git push -q -u origin "$release_branch"
gh pr create --base main --head "$release_branch" --title "Release $tag" --body "Bumps the version to $next."
git switch -q main

echo
echo "Next: merge the pull request, then run:"
echo "  git pull"
echo "  scripts/publish-release.sh --apply"
