#!/bin/bash
# A release without an Apple Developer account (docs/RELEASE.md):
#   scripts/release.sh <version> [--publish]
# Builds Release, signs it with the self-signed «ClaudePult Release» certificate (always the same one, so macOS
# keeps permissions and Sparkle accepts the update; the certificate keeps the app's old name), makes AIHubBar-<version>.dmg, signs it for Sparkle and writes
# appcast.xml into build/release/<version>/. With --publish it creates the GitHub release v<version> with both files
# (the repository must be public for people to download them).
# Keys: $CLAUDEPULT_RELEASE_DIR (default ~/Library/Application Support/ClaudePult-release), made once by
# scripts/release-tools/make-signing-cert.sh and `swift scripts/release-tools/sparkle-key.swift keygen`.
set -euo pipefail

VERSION="${1:-}"
PUBLISH="${2:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "usage: scripts/release.sh <version, e.g. 0.2.0> [--publish]" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
KEYS="${CLAUDEPULT_RELEASE_DIR:-$HOME/Library/Application Support/ClaudePult-release}"
for file in codesign.p12 codesign.pass sparkle-ed25519.key; do
  [[ -f "$KEYS/$file" ]] || { echo "Missing $KEYS/$file — see docs/RELEASE.md (one-time setup)." >&2; exit 1; }
done
if [[ -n "$(git status --porcelain)" ]]; then
  echo "The working tree has changes; release from a clean checkout." >&2
  exit 1
fi

BUILD_NUMBER="$(git rev-list --count HEAD)"
OUT="$ROOT/build/release/$VERSION"
DERIVED="$ROOT/build/release/DerivedData"
REPO="OlehDemishev/AIHubBar"
DMG="AIHubBar-$VERSION.dmg"
NAME="AI Hub Bar"
rm -rf "$OUT" && mkdir -p "$OUT"

echo "==> Building $VERSION ($BUILD_NUMBER)"
xcodegen generate >/dev/null
xcodebuild -project ClaudePult.xcodeproj -scheme ClaudePult -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build >"$OUT/build.log" 2>&1 \
  || { tail -30 "$OUT/build.log" >&2; exit 1; }
APP="$OUT/$NAME.app"
ditto "$DERIVED/Build/Products/Release/AIHubBar.app" "$APP"

echo "==> Signing with «ClaudePult Release»"
KC="$(mktemp -d)/release.keychain-db"
KCPASS="$(openssl rand -hex 16)"
cleanup() { security delete-keychain "$KC" 2>/dev/null || true; }
trap cleanup EXIT
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings -lut 900 "$KC"
security unlock-keychain -p "$KCPASS" "$KC"
security import "$KEYS/codesign.p12" -k "$KC" -P "$(cat "$KEYS/codesign.pass")" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null 2>&1
# Each part keeps its entitlements (the widget's sandbox) minus the debugger's get-task-allow, which a release
# shouldn't carry.
sign() {
  local target="$1" entitlements
  entitlements="$(mktemp)"
  codesign -d --entitlements - --xml "$target" >"$entitlements" 2>/dev/null || true
  if [[ -s "$entitlements" ]]; then
    /usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$entitlements" >/dev/null 2>&1 || true
    codesign --force --keychain "$KC" -s "ClaudePult Release" --entitlements "$entitlements" "$target"
  else
    codesign --force --keychain "$KC" -s "ClaudePult Release" "$target"
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
sign "$APP"
codesign --verify --deep --strict "$APP"
AUTHORITY="$(codesign -dvv "$APP" 2>&1 | grep '^Authority=' | head -1)"
echo "    $AUTHORITY"

echo "==> Making $DMG"
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$OUT/$DMG" >/dev/null 2>&1
rm -rf "$STAGE"

echo "==> Signing the update for Sparkle"
SIGNATURE="$(swift scripts/release-tools/sparkle-key.swift sign "$OUT/$DMG")"
[[ "$(swift scripts/release-tools/sparkle-key.swift verify "$OUT/$DMG" "$SIGNATURE")" == "valid" ]] || { echo "Signature check failed" >&2; exit 1; }
LENGTH="$(stat -f%z "$OUT/$DMG")"
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$NAME</title>
    <link>https://github.com/$REPO/releases</link>
    <item>
      <title>$NAME $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/$DMG" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$OUT/appcast.xml"

echo "==> Ready in $OUT"
ls -lh "$OUT/$DMG" "$OUT/appcast.xml" | awk '{print "    " $5 "  " $9}'

if [[ "$PUBLISH" == "--publish" ]]; then
  echo "==> Publishing v$VERSION"
  # The overview PDFs (scripts/make-overview-pdf.sh) go along when they exist.
  EXTRA=()
  for pdf in docs/AI-Hub-Bar-Overview-*.pdf; do [ -f "$pdf" ] && EXTRA+=("$pdf"); done
  gh release create "v$VERSION" "$OUT/$DMG" "$OUT/appcast.xml" ${EXTRA[@]+"${EXTRA[@]}"} --repo "$REPO" --title "$NAME $VERSION" \
    --notes "Download $DMG, open it and drag AI Hub Bar to Applications. The first launch asks once: System Settings → Privacy & Security → **Open Anyway** (see docs/GUIDE.md). What AI Hub Bar does: AI-Hub-Bar-Overview-en.pdf (русский: AI-Hub-Bar-Overview-ru.pdf)."
else
  echo "Not published. To publish: scripts/release.sh $VERSION --publish (or gh release create v$VERSION with both files)."
fi
