#!/bin/bash
# Everything to run before a push (docs/specs/SPEC-refactor.md §7): the Mac unit tests, the string catalog, the
# desktop texts check and the Telegram relay's tests. CI runs the same (.github/workflows/mac.yml).
#
# Usage: scripts/check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Strings"
python3 scripts/strings-check.py
python3 desktop/scripts/strings.py --check

echo "==> Relay tests"
if command -v node >/dev/null; then (cd relay/telegram && node --test); else echo "node not found: relay tests skipped"; fi

echo "==> Mac tests"
xcodegen generate --quiet
# Swift warnings fail here, with the Xcode releases are built with; CI's older Xcode may warn differently, so not there.
xcodebuild test -project AIHubBar.xcodeproj -scheme AIHubBar \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData -testLanguage ru -testRegion RU -quiet \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

echo "==> Strings against the code"
# A copy synced with what this build compiled: a new text with no translations, or a text the code no longer uses.
OBJECTS="build/DerivedData/Build/Intermediates.noindex/AIHubBar.build/Debug/AIHubBar.build/Objects-normal/arm64"
SYNCED="$(mktemp -d)/Localizable.xcstrings"
cp AIHubBar/Resources/Localizable.xcstrings "$SYNCED"
xcrun xcstringstool sync "$SYNCED" --stringsdata "$OBJECTS"/*.stringsdata
python3 scripts/strings-check.py --catalog "$SYNCED" \
  || { echo "The catalog is behind the code: run scripts/strings-sync.sh, translate, remove what it marks." >&2; exit 1; }
echo "All checks passed."
