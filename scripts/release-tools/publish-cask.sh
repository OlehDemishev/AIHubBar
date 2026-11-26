#!/bin/bash
# Copies the cask (Casks/ai-hub-bar.rb) into the tap people install from, OlehDemishev/homebrew-tap
# (docs/RELEASE.md «Homebrew»):
#   scripts/release-tools/publish-cask.sh
# Run it after update-cask.sh, once the cask of the new release is in `main`. Needs `gh` signed in with push rights.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CASK="$ROOT/Casks/ai-hub-bar.rb"
TAP="OlehDemishev/homebrew-tap"
FILE="Casks/ai-hub-bar.rb"
VERSION="$(sed -n -E 's/^  version "([^"]*)"/\1/p' "$CASK")"
[[ -n "$VERSION" ]] || { echo "No version in $CASK." >&2; exit 1; }

REMOTE="$(gh api "repos/$TAP/contents/$FILE" --jq '.sha + " " + .content' 2>/dev/null || true)"
SHA="${REMOTE%% *}"
if [[ -n "$SHA" && "$(printf '%s' "${REMOTE#* }" | base64 -d 2>/dev/null)" == "$(cat "$CASK")" ]]; then
    echo "The tap already has the cask of $VERSION."
    exit 0
fi

ARGS=(-X PUT "repos/$TAP/contents/$FILE" -f "message=Update the AI Hub Bar cask to $VERSION" -f "content=$(base64 < "$CASK" | tr -d '\n')")
[[ -n "$SHA" ]] && ARGS+=(-f "sha=$SHA")
gh api "${ARGS[@]}" --jq '.commit.html_url'
