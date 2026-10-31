#!/bin/bash
# Renders docs/overview/overview.<lang>.html to docs/AI-Hub-Bar-Overview-<lang>.pdf and the hero images with headless Google Chrome.
# Usage: scripts/make-overview-pdf.sh [lang ...]   (default: every overview.*.html)
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "Google Chrome not found at $CHROME" >&2; exit 1; }

langs=("$@")
if [ ${#langs[@]} -eq 0 ]; then
  for f in docs/overview/overview.*.html; do
    l=${f#docs/overview/overview.}; langs+=("${l%.html}")
  done
fi

for lang in "${langs[@]}"; do
  src="$PWD/docs/overview/overview.$lang.html"
  out="$PWD/docs/AI-Hub-Bar-Overview-$lang.pdf"
  "$CHROME" --headless=new --disable-gpu --no-pdf-header-footer --allow-file-access-from-files \
    --print-to-pdf="$out" "file://$src" 2>/dev/null
  echo "$out"
done

# README header (2x) and GitHub social preview (1280×640) from docs/overview/hero.html.
mkdir -p docs/images
for scale in 2 1; do
  out="$PWD/docs/images/hero.png"; [ $scale = 1 ] && out="$PWD/docs/images/social-preview.png"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --window-size=1280,640 --force-device-scale-factor=$scale \
    --screenshot="$out" "file://$PWD/docs/overview/hero.html" 2>/dev/null
  echo "$out"
done
