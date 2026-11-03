#!/bin/bash
# Exports the help window's topics into site/help/<language>.json, one file per interface language, for the site's
# help page (docs/specs/SPEC-help.md §4). Run after changing the help texts or their translations, then commit site/help/.
#
# Usage: scripts/export-help.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build/DerivedData"
LANGUAGES=(ru en uk de fr es it pt-BR pl ja ko ar id)

cd "$ROOT"
echo "==> Building"
xcodegen generate --quiet
xcodebuild build -project AIHubBar.xcodeproj -scheme AIHubBar -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" -quiet
APP="$DERIVED/Build/Products/Debug/AIHubBar.app/Contents/MacOS/AIHubBar"

mkdir -p site/help
for language in "${LANGUAGES[@]}"; do
  "$APP" --help-export "site/help/$language.json" -AppleLanguages "($language)"
done
echo "Done: site/help/*.json"
