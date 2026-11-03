#!/bin/bash
# Brings new interface strings into the catalog and checks it (docs/SPEC-refactor.md §7; it was done by hand,
# DECISIONS.md «Catalog upkeep»): builds Debug, syncs ClaudePult/Resources/Localizable.xcstrings from the compiler's
# .stringsdata, rewrites it in the repository's JSON style (Xcode's style would rewrite every line) and runs
# scripts/strings-check.py. New strings then need translations: the check lists them.
#
# Usage: scripts/strings-sync.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build/DerivedData"
cd "$ROOT"

echo "==> Building"
xcodegen generate --quiet
xcodebuild build -project ClaudePult.xcodeproj -scheme ClaudePult -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" -quiet
OBJECTS="$DERIVED/Build/Intermediates.noindex/ClaudePult.build/Debug/ClaudePult.build/Objects-normal/arm64"

echo "==> Syncing the catalog"
xcrun xcstringstool sync ClaudePult/Resources/Localizable.xcstrings --stringsdata "$OBJECTS"/*.stringsdata
python3 scripts/strings-check.py --format
