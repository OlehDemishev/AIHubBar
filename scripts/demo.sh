#!/bin/bash
# The demo copy of AI Hub Bar, for recording news about a release: the app filled with sample data (AIHubBar/App/
# DemoMode.swift, DemoData.swift). It is a copy with its own bundle id and its own home folder under build/demo/, so
# it never reads or changes the installed app's settings, profiles or sign-ins, and it asks no service for anything.
# The installed app cannot be switched into this mode; this script is the only way in.
#
# Usage: scripts/demo.sh [scene] [--lang <code>] [--open <window>] [--solo] [--debug] [--no-build]
#        scripts/demo.sh stop
#   scene      default (Claude leads) or codex-main (no Claude: Codex leads) — DemoMode.Scene
#   --lang     interface language of the copy: en, ru, de… (default: the Mac's)
#   --open     a window to open at the start: limits, usage-history, settings, help, calendar…  (WindowID);
#              it comes to the front and takes the keyboard
#   --solo     quit the installed app first, so one item is in the menu bar; `stop` opens it again
#   --debug    use the Debug build that scripts/check.sh leaves (faster; shows version 0.1.0)
#   --no-build use the build that is already there
#   stop       quit the copy and delete its home folder
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build/DerivedData"
DEMO="$ROOT/build/demo"
APP="$DEMO/AI Hub Bar Demo.app"
HOME_DIR="$DEMO/home"
SOLO_MARK="$DEMO/solo"
DEMO_ID="com.demishev.claudepult.demo"
REAL_ID="com.demishev.claudepult"
INSTALLED="$HOME/Applications/AI Hub Bar.app"

stop_demo() {
  pkill -f "$APP/Contents/MacOS/" 2>/dev/null || true
  for _ in {1..20}; do pgrep -f "$APP/Contents/MacOS/" >/dev/null || break; sleep 0.25; done
}

SCENE="default"; LANGUAGE=""; OPEN_WINDOW=""; SOLO=0; CONFIG="Release"; BUILD=1; STOP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    stop) STOP=1 ;;
    --lang) LANGUAGE="${2:?--lang needs a language code}"; shift ;;
    --open) OPEN_WINDOW="${2:?--open needs a window}"; shift ;;
    --solo) SOLO=1 ;;
    --debug) CONFIG="Debug" ;;
    --no-build) BUILD=0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) SCENE="$1" ;;
  esac
  shift
done

if [[ $STOP -eq 1 ]]; then
  stop_demo
  rm -rf "$HOME_DIR"
  defaults delete "$DEMO_ID" >/dev/null 2>&1 || true
  if [[ -f "$SOLO_MARK" ]]; then
    rm -f "$SOLO_MARK"
    [[ -d "$INSTALLED" ]] && open -g "$INSTALLED"
  fi
  echo "The demo copy is stopped."
  exit 0
fi

grep -q "case .* = \"$SCENE\"" "$ROOT/AIHubBar/App/DemoMode.swift" || [[ "$SCENE" == "default" ]] \
  || { echo "Unknown scene: $SCENE (see DemoMode.Scene)" >&2; exit 2; }

cd "$ROOT"
BUILT="$DERIVED/Build/Products/$CONFIG/AIHubBar.app"
if [[ $BUILD -eq 1 ]]; then
  command -v xcodegen >/dev/null || { echo "xcodegen not found. Install it: brew install xcodegen" >&2; exit 1; }
  xcodegen generate --quiet
  # Numbered like scripts/build-and-install.sh: the newest release tag, so the copy shows the version being recorded.
  VERSION="$(git tag -l 'v*' --sort=-v:refname | grep -v -- '-beta' | head -1)"
  VERSION="${VERSION#v}"; VERSION="${VERSION:-0.1.0}"
  echo "==> Building $CONFIG $VERSION"
  if [[ "$CONFIG" == "Release" ]]; then
    xcodebuild build -project AIHubBar.xcodeproj -scheme AIHubBar -configuration Release \
      -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
      MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" -quiet
  else
    xcodebuild build -project AIHubBar.xcodeproj -scheme AIHubBar -configuration Debug \
      -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" -quiet
  fi
fi
[[ -d "$BUILT" ]] || { echo "No build at $BUILT" >&2; exit 1; }

echo "==> Making the copy"
stop_demo
rm -rf "$APP" "$HOME_DIR"
mkdir -p "$DEMO" "$HOME_DIR"
ditto "$BUILT" "$APP"
# The copy must not answer for the installed app: no widget, no aihubbar:// links, no *.claudepult files.
rm -rf "$APP/Contents/PlugIns"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DEMO_ID" "$PLIST"
for key in CFBundleURLTypes CFBundleDocumentTypes UTExportedTypeDeclarations; do
  /usr/libexec/PlistBuddy -c "Delete :$key" "$PLIST" 2>/dev/null || true
done
codesign --force --deep --sign - "$APP" 2>/dev/null
defaults delete "$DEMO_ID" >/dev/null 2>&1 || true

if [[ $SOLO -eq 1 ]]; then
  echo "==> Quitting the installed app (scripts/demo.sh stop opens it again)"
  osascript -e "tell application id \"$REAL_ID\" to quit" >/dev/null 2>&1 || true
  touch "$SOLO_MARK"
fi

echo "==> Starting scene «$SCENE»"
ARGS=()
[[ -n "$LANGUAGE" ]] && ARGS=(--args -AppleLanguages "($LANGUAGE)")
ENV=(--env "CFFIXED_USER_HOME=$HOME_DIR" --env "AIHUBBAR_DEMO_SCENE=$SCENE")
[[ -n "$OPEN_WINDOW" ]] && ENV+=(--env "AIHUBBAR_DEMO_OPEN=$OPEN_WINDOW")
open -n -g "${ENV[@]}" "$APP" ${ARGS[@]+"${ARGS[@]}"}
echo "The demo copy is running: its item is in the menu bar. Stop it with: scripts/demo.sh stop"
