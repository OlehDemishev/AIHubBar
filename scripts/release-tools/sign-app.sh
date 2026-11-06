#!/bin/bash
# Signs a built «AI Hub Bar.app» with the Developer ID certificate (docs/RELEASE.md):
#   scripts/release-tools/sign-app.sh <path to .app>
# Used by scripts/release.sh and by scripts/build-and-install.sh, so a local build carries the same signature as a
# release and macOS keeps its permissions (Accessibility for «Раскладка», Automation) from build to build.
# Keys: $CLAUDEPULT_RELEASE_DIR (default ~/Library/Application Support/ClaudePult-release). The certificate goes into a
# temporary keychain, deleted at the end. Apple's intermediate certificate has to be in the login keychain, or codesign
# can't build the chain (docs/RELEASE.md, one-time setup). SIGN_TIMESTAMP=1 asks Apple for a secure timestamp, which
# notarization needs; a local build goes without, so it works offline.
set -euo pipefail

APP="${1:?usage: sign-app.sh <path to .app>}"
KEYS="${CLAUDEPULT_RELEASE_DIR:-$HOME/Library/Application Support/ClaudePult-release}"
IDENTITY="Developer ID Application: Oleh Demishev (365835Q3S6)"
ENTITLEMENTS="$(cd "$(dirname "$0")" && pwd)/app.entitlements"
TIMESTAMP=()
[[ "${SIGN_TIMESTAMP:-}" == "1" ]] && TIMESTAMP=(--timestamp)
for file in developer-id.p12 developer-id.pass; do
  [[ -f "$KEYS/$file" ]] || { echo "Missing $KEYS/$file — see docs/RELEASE.md (one-time setup)." >&2; exit 1; }
done

KC="$(mktemp -d)/release.keychain-db"
KCPASS="$(openssl rand -hex 16)"
cleanup() { security delete-keychain "$KC" 2>/dev/null || true; }
trap cleanup EXIT
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings -lut 900 "$KC"
security unlock-keychain -p "$KCPASS" "$KC"
security import "$KEYS/developer-id.p12" -k "$KC" -P "$(cat "$KEYS/developer-id.pass")" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null 2>&1
# A disk image is signed as it is.
if [[ "$APP" == *.dmg ]]; then
  codesign --force --keychain "$KC" -s "$IDENTITY" ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} "$APP"
  codesign --verify "$APP"
  exit 0
fi

# Hardened runtime everywhere: notarization requires it. Each part keeps its entitlements (the widget's sandbox) minus
# the debugger's get-task-allow, which a release shouldn't carry.
sign() {
  local target="$1" entitlements
  entitlements="$(mktemp)"
  codesign -d --entitlements - --xml "$target" >"$entitlements" 2>/dev/null || true
  if [[ -s "$entitlements" ]]; then
    /usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$entitlements" >/dev/null 2>&1 || true
    codesign --force --keychain "$KC" -s "$IDENTITY" --options runtime ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} --entitlements "$entitlements" "$target"
  else
    codesign --force --keychain "$KC" -s "$IDENTITY" --options runtime ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} "$target"
  fi
  rm -f "$entitlements"
}
# Inside out: Sparkle's helpers, the framework, the widget, then the app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE/XPCServices/Installer.xpc"
sign "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
for extension in "$APP"/Contents/PlugIns/*.appex; do sign "$extension"; done
# The app drives Terminal with Apple Events, which the hardened runtime blocks without this entitlement.
codesign --force --keychain "$KC" -s "$IDENTITY" --options runtime ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"
codesign -dvv "$APP" 2>&1 | grep '^Authority=' | head -1 | sed 's/^/    /'
