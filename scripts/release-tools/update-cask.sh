#!/bin/bash
# Points the Homebrew cask (Casks/ai-hub-bar.rb) at a published release (docs/RELEASE.md «Homebrew»):
#   scripts/release-tools/update-cask.sh <version>
# Takes the checksum of build/release/<version>/AIHubBar-<version>.dmg — the file scripts/release.sh uploaded. Run it
# after a release, on the branch that records the release in docs/STATUS.md; betas are not put into the cask.
set -euo pipefail

VERSION="${1:?usage: update-cask.sh <version>}"
[[ "$VERSION" == *-beta.* ]] && { echo "A beta does not go into the cask." >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DMG="$ROOT/build/release/$VERSION/AIHubBar-$VERSION.dmg"
CASK="$ROOT/Casks/ai-hub-bar.rb"
[[ -f "$DMG" ]] || { echo "No $DMG — release $VERSION on this Mac first." >&2; exit 1; }

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
sed -i '' -E "s/^  version \"[^\"]*\"/  version \"$VERSION\"/; s/^  sha256 \"[^\"]*\"/  sha256 \"$SHA\"/" "$CASK"
grep -E '^  (version|sha256) ' "$CASK"
