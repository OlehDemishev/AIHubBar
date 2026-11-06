#!/bin/bash
# Build AI Hub Bar (Release), install it into ~/Applications and (re)launch it.
# Xcode project and scheme AIHubBar; the app is «AI Hub Bar.app» with the executable AIHubBar (bundle id still claudepult).
#
# Usage: scripts/build-and-install.sh [--test] [--no-launch]
#   --test       run unit tests before building
#   --no-launch  install without launching
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="AIHubBar"
OLD_NAME="ClaudePult"  # the app before the rename to AI Hub Bar
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
    -project "$PROJECT.xcodeproj" -scheme "$PROJECT" \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
    -quiet
fi

# Numbered like scripts/release.sh (build = commit count), so Sparkle never takes a build from main for older than the
# last release and «updates» it back to that release. Version: the newest release tag.
BUILD_NUMBER="$(git rev-list --count HEAD)"
VERSION="$(git tag -l 'v*' --sort=-v:refname | grep -v -- '-beta' | head -1)"
VERSION="${VERSION#v}"
VERSION="${VERSION:-0.1.0}"

echo "==> Building Release $VERSION ($BUILD_NUMBER)"
# A fresh bundle: Xcode keeps files of renamed targets (the old ClaudePultWidget.appex) in a reused one.
rm -rf "$DERIVED/Build/Products/Release/$EXECUTABLE.app"
xcodebuild build \
  -project "$PROJECT.xcodeproj" -scheme "$PROJECT" -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -quiet

BUILT="$DERIVED/Build/Products/Release/$EXECUTABLE.app"
[[ -d "$BUILT" ]] || { echo "Build product not found: $BUILT" >&2; exit 1; }

echo "==> Stopping the running app"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in {1..20}; do
  pgrep -xq "$EXECUTABLE" || pgrep -xq "$OLD_NAME" || break
  sleep 0.25
done
pkill -x "$EXECUTABLE" 2>/dev/null || true
pkill -x "$OLD_NAME" 2>/dev/null || true

# The app used to be installed as ClaudePult.app: two copies with one bundle id confuse macOS. To the Trash, not deleted.
OLD="$INSTALL_DIR/$OLD_NAME.app"
if [[ -d "$OLD" ]]; then
  echo "==> Moving the old $OLD_NAME.app to the Trash"
  mv "$OLD" "$HOME/.Trash/$OLD_NAME-$(date +%Y%m%d-%H%M%S).app"
fi

echo "==> Installing to $DEST"
mkdir -p "$INSTALL_DIR"
rm -rf "$DEST"
ditto "$BUILT" "$DEST"

# The release certificate, when this Mac has it: macOS then keeps the app's permissions (Accessibility for
# «Раскладка») across builds. An ad-hoc signature changes with every build, and macOS forgets them.
KEYS="${CLAUDEPULT_RELEASE_DIR:-$HOME/Library/Application Support/ClaudePult-release}"
if [[ -f "$KEYS/developer-id.p12" ]]; then
  echo "==> Signing with Developer ID"
  "$ROOT/scripts/release-tools/sign-app.sh" "$DEST"
else
  echo "    (signed ad hoc: no release certificate in $KEYS, so macOS asks for permissions again after each build)"
fi

if [[ $LAUNCH -eq 1 ]]; then
  echo "==> Launching"
  open "$DEST"
fi
echo "Done: $DEST"
