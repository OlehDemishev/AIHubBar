#!/bin/bash
# Build ClaudeBar (Release), install it into ~/Applications and (re)launch it.
#
# Usage: scripts/build-and-install.sh [--test] [--no-launch]
#   --test       run unit tests before building
#   --no-launch  install without launching
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ClaudeBar"
BUNDLE_ID="com.demishev.claudebar"
DERIVED="$ROOT/build/DerivedData"
INSTALL_DIR="$HOME/Applications"
DEST="$INSTALL_DIR/$APP_NAME.app"

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

BUILT="$DERIVED/Build/Products/Release/$APP_NAME.app"
[[ -d "$BUILT" ]] || { echo "Build product not found: $BUILT" >&2; exit 1; }

echo "==> Stopping running $APP_NAME"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in {1..20}; do
  pgrep -xq "$APP_NAME" || break
  sleep 0.25
done
pkill -x "$APP_NAME" 2>/dev/null || true

echo "==> Installing to $DEST"
mkdir -p "$INSTALL_DIR"
rm -rf "$DEST"
ditto "$BUILT" "$DEST"

if [[ $LAUNCH -eq 1 ]]; then
  echo "==> Launching"
  open "$DEST"
fi
echo "Done: $DEST"
