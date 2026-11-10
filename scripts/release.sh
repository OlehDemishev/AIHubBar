#!/bin/bash
# A release without an Apple Developer account (docs/RELEASE.md):
#   scripts/release.sh <version> [--publish]
#   scripts/release.sh <version>-beta.<n> [--publish]   a beta build: a GitHub pre-release, offered only to beta testers
# Builds Release, signs it with the Developer ID certificate, notarizes and staples it (the notarytool profile «AIHubBar»),
# makes AIHubBar-<version>.dmg, notarizes that too, signs it for Sparkle and writes
# appcast.xml into build/release/<version>/. With --publish it creates the GitHub release v<version> with both files
# (the repository must be public for people to download them), and replaces the beta channel's appcast (the release
# tagged `beta`) with the newest release and the newest beta (scripts/release-tools/beta-feed.py).
# Keys: $CLAUDEPULT_RELEASE_DIR (default ~/Library/Application Support/ClaudePult-release), made once by
# scripts/release-tools/make-signing-cert.sh and `swift scripts/release-tools/sparkle-key.swift keygen`.
set -euo pipefail

VERSION="${1:-}"
PUBLISH="${2:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?(-beta\.[0-9]+)?$ ]]; then
  echo "usage: scripts/release.sh <version, e.g. 0.2.0 or 0.3.0-beta.1> [--publish]" >&2
  exit 1
fi
BETA=0
[[ "$VERSION" == *-beta.* ]] && BETA=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
KEYS="${CLAUDEPULT_RELEASE_DIR:-$HOME/Library/Application Support/ClaudePult-release}"
for file in developer-id.p12 developer-id.pass sparkle-ed25519.key; do
  [[ -f "$KEYS/$file" ]] || { echo "Missing $KEYS/$file — see docs/RELEASE.md (one-time setup)." >&2; exit 1; }
done
if [[ -n "$(git status --porcelain)" ]]; then
  echo "The working tree has changes; release from a clean checkout." >&2
  exit 1
fi

# Nothing ships without the tests and the string catalog passing (docs/specs/SPEC-refactor.md §7).
scripts/check.sh

BUILD_NUMBER="$(git rev-list --count HEAD)"
OUT="$ROOT/build/release/$VERSION"
DERIVED="$ROOT/build/release/DerivedData"
REPO="OlehDemishev/AIHubBar"
DMG="AIHubBar-$VERSION.dmg"
NAME="AI Hub Bar"
rm -rf "$OUT" && mkdir -p "$OUT"
# What changed, written by hand (docs/RELEASE.md «Release notes»): the release page and Sparkle's update window show
# it. A beta takes its own file, else the one of the version it leads to.
NOTES_FILE="docs/release-notes/$VERSION.md"
[[ -f "$NOTES_FILE" ]] || NOTES_FILE="docs/release-notes/${VERSION%%-beta.*}.md"
if [[ ! -f "$NOTES_FILE" ]]; then
  NOTES_FILE=""
  echo "!!  No docs/release-notes/$VERSION.md: people will update without knowing what changed."
fi

echo "==> Building $VERSION ($BUILD_NUMBER)"
xcodegen generate >/dev/null
# A fresh bundle: Xcode keeps files of renamed targets (the old ClaudePultWidget.appex) in a reused one.
rm -rf "$DERIVED/Build/Products/Release/AIHubBar.app"
xcodebuild -project AIHubBar.xcodeproj -scheme AIHubBar -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build >"$OUT/build.log" 2>&1 \
  || { tail -30 "$OUT/build.log" >&2; exit 1; }
APP="$OUT/$NAME.app"
ditto "$DERIVED/Build/Products/Release/AIHubBar.app" "$APP"

echo "==> Signing with Developer ID"
SIGN_TIMESTAMP=1 scripts/release-tools/sign-app.sh "$APP"

notarize() {
  xcrun notarytool submit "$1" --keychain-profile AIHubBar --wait --timeout 30m | tee "$OUT/notary.log" | tail -3
  grep -q 'status: Accepted' "$OUT/notary.log" || { echo "Notarization failed: $1" >&2; exit 1; }
}

echo "==> Notarizing the app"
ZIP="$OUT/notarize.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
rm -f "$ZIP"
xcrun stapler staple "$APP"

echo "==> Making $DMG"
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$OUT/$DMG" >/dev/null 2>&1
rm -rf "$STAGE"

echo "==> Notarizing the disk image"
SIGN_TIMESTAMP=1 scripts/release-tools/sign-app.sh "$OUT/$DMG"
notarize "$OUT/$DMG"
xcrun stapler staple "$OUT/$DMG"
spctl --assess --type open --context context:primary-signature "$OUT/$DMG"

echo "==> Signing the update for Sparkle"
SIGNATURE="$(swift scripts/release-tools/sparkle-key.swift sign "$OUT/$DMG")"
[[ "$(swift scripts/release-tools/sparkle-key.swift verify "$OUT/$DMG" "$SIGNATURE")" == "valid" ]] || { echo "Signature check failed" >&2; exit 1; }
LENGTH="$(stat -f%z "$OUT/$DMG")"
# Only beta testers' copies take an item marked with the beta channel (Updates.swift).
CHANNEL=""
if [[ $BETA -eq 1 ]]; then CHANNEL=$'\n      <sparkle:channel>beta</sparkle:channel>'; fi
NOTES_XML="      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>"
if [[ -n "$NOTES_FILE" ]]; then
  NOTES_XML="      <description><![CDATA[$(python3 scripts/release-tools/release-notes.py "$NOTES_FILE")]]></description>"
fi
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
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>$CHANNEL
$NOTES_XML
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
  NOTES="Download $DMG, open it and drag AI Hub Bar to Applications."
  if [[ -n "$NOTES_FILE" ]]; then NOTES="$(cat "$NOTES_FILE")"$'\n\n'"$NOTES"; fi
  if [[ $BETA -eq 1 ]]; then
    # A pre-release is never «latest», so copies outside the beta channel don't see it.
    gh release create "v$VERSION" "$OUT/$DMG" "$OUT/appcast.xml" --repo "$REPO" --title "$NAME $VERSION" --prerelease \
      --notes "**Beta build** for beta testers (Settings → General → Beta builds)."$'\n\n'"$NOTES"
  else
    gh release create "v$VERSION" "$OUT/$DMG" "$OUT/appcast.xml" ${EXTRA[@]+"${EXTRA[@]}"} --repo "$REPO" --title "$NAME $VERSION" \
      --notes "$NOTES"
  fi

  echo "==> Updating the beta channel"
  FEEDS="$(mktemp -d)"
  mkdir -p "$FEEDS/beta" "$FEEDS/latest" "$FEEDS/out"
  gh release download beta --repo "$REPO" --pattern appcast.xml --dir "$FEEDS/beta" 2>/dev/null || true
  gh release download --repo "$REPO" --pattern appcast.xml --dir "$FEEDS/latest" 2>/dev/null || true
  python3 scripts/release-tools/beta-feed.py "$FEEDS/out/appcast.xml" "$FEEDS/beta/appcast.xml" "$FEEDS/latest/appcast.xml" "$OUT/appcast.xml"
  xmllint --noout "$FEEDS/out/appcast.xml"
  gh release view beta --repo "$REPO" >/dev/null 2>&1 \
    || gh release create beta --repo "$REPO" --target main --prerelease --title "$NAME beta channel" \
         --notes "Not a build: holds the appcast that beta testers' copies read (docs/RELEASE.md)."
  gh release upload beta "$FEEDS/out/appcast.xml" --repo "$REPO" --clobber
else
  echo "Not published. To publish: scripts/release.sh $VERSION --publish (or gh release create v$VERSION with both files)."
fi
