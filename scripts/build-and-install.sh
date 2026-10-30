#!/bin/bash
# Build AI Hub Bar (Release), install it into ~/Applications and (re)launch it.
# The Xcode project and scheme keep the old name ClaudePult; the app is «AI Hub Bar.app» with the executable AIHubBar.
#
# Usage: scripts/build-and-install.sh [--test] [--no-launch]
#   --test       run unit tests before building
#   --no-launch  install without launching
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ClaudePult"
EXECUTABLE="AIHubBar"
DISPLAY_NAME="AI Hub Bar"
BUNDLE_ID="com.demishev.claudepult"
DERIVED="$ROOT/build/DerivedData"
INSTALL_DIR="$HOME/Applications"
DEST="$INSTALL_DIR/$DISPLAY_NAME.app"

RUN_TESTS=0
LAUNCH=1
for arg in "$@"; do
  case "$arg" in
    --test) RUN_TESTS=1 ;;
    --no-launch) LAUNCH=0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Install it: brew install xcodegen" >&2
  exit 1
fi

cd "$ROOT"
echo "==> Generating Xcode project"
xcodegen generate --quiet

if [[ $RUN_TESTS -eq 1 ]]; then
  echo "==> Running tests"
  xcodebuild test \
    -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
    -quiet
fi

echo "==> Building Release"
xcodebuild build \
  -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
  -quiet

BUILT="$DERIVED/Build/Products/Release/$EXECUTABLE.app"
[[ -d "$BUILT" ]] || { echo "Build product not found: $BUILT" >&2; exit 1; }

echo "==> Stopping the running app"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in {1..20}; do
  pgrep -xq "$EXECUTABLE" || pgrep -xq "$APP_NAME" || break
  sleep 0.25
done
pkill -x "$EXECUTABLE" 2>/dev/null || true
pkill -x "$APP_NAME" 2>/dev/null || true

# The app used to be installed as ClaudePult.app: two copies with one bundle id confuse macOS. To the Trash, not deleted.
OLD="$INSTALL_DIR/$APP_NAME.app"
if [[ -d "$OLD" ]]; then
  echo "==> Moving the old $APP_NAME.app to the Trash"
  mv "$OLD" "$HOME/.Trash/$APP_NAME-$(date +%Y%m%d-%H%M%S).app"
fi

echo "==> Installing to $DEST"
mkdir -p "$INSTALL_DIR"
rm -rf "$DEST"
ditto "$BUILT" "$DEST"

if [[ $LAUNCH -eq 1 ]]; then
  echo "==> Launching"
  open "$DEST"
fi
echo "Done: $DEST"
