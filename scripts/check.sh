#!/bin/bash
# Everything to run before a push (docs/specs/SPEC-refactor.md §7): the Mac unit tests, the string catalog, and the
# desktop texts check. CI runs the same (.github/workflows/mac.yml).
#
# Usage: scripts/check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Strings"
python3 scripts/strings-check.py
python3 desktop/scripts/strings.py --check

echo "==> Mac tests"
xcodegen generate --quiet
xcodebuild test -project AIHubBar.xcodeproj -scheme AIHubBar \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData -testLanguage ru -testRegion RU -quiet
echo "All checks passed."
