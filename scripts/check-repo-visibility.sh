#!/bin/bash
# Compares docs/github-visibility (expected) with the live GitHub repo
# visibility. One gh API call, no polling. Called from publish-release.sh
# so a private→public flip is noticed the next time you cut a release.
#
# Usage: scripts/check-repo-visibility.sh
# Exit 0 when they match, 1 on mismatch or lookup failure.
set -euo pipefail

root="$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)"
cd "$root"

marker="$root/docs/github-visibility"
if [ ! -f "$marker" ]; then
    echo "check-repo-visibility: missing $marker (expected one word: private or public)" >&2
    exit 1
fi
expected="$(tr -d '[:space:]' < "$marker" | tr '[:upper:]' '[:lower:]')"
case "$expected" in
    private|public) ;;
    *)
        echo "check-repo-visibility: $marker must be 'private' or 'public', got '$expected'" >&2
        exit 1
        ;;
esac

if ! command -v gh >/dev/null 2>&1; then
    echo "check-repo-visibility: gh (GitHub CLI) is required" >&2
    exit 1
fi

is_private="$(gh repo view --json isPrivate -q .isPrivate 2>/dev/null || true)"
case "$is_private" in
    true) actual=private ;;
    false) actual=public ;;
    *)
        echo "check-repo-visibility: could not read repo visibility (gh auth? network?)" >&2
        exit 1
        ;;
esac

if [ "$actual" = "$expected" ]; then
    echo "Repo visibility: $actual (matches docs/github-visibility)"
    exit 0
fi

echo "check-repo-visibility: expected $expected (docs/github-visibility) but GitHub reports $actual." >&2
if [ "$actual" = "public" ]; then
    echo "Repo is now public. Follow docs/BUILD.md \"When the GitHub repo becomes public\", then set docs/github-visibility to public." >&2
else
    echo "Repo is private again. Restore token-based update auth if you stripped it, then set docs/github-visibility to private." >&2
fi
exit 1
