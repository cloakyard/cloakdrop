#!/usr/bin/env bash
# Render the Open Graph card — assets/social/og.html → assets/social/og.png (1200×630).
#
# The card is HTML so it stays in sync with the site's design system (same fonts, colours and
# tracking) and so a copy change never means re-doing pixels. Chrome screenshots it at 1×;
# --allow-file-access-from-files is what lets the file:// page load the woff2 fonts and the SVG
# mark next to it.
#
# Usage:  scripts/make-og.sh            # then: node scripts/sync-assets.mjs
#
# macOS + Google Chrome. Override the binary with CHROME=/path/to/chrome if you use another
# Chromium build.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/assets/social/og.html"
OUT="$REPO/assets/social/og.png"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

if [[ ! -x "$CHROME" ]]; then
  echo "error: Chrome not found at $CHROME (set CHROME=/path/to/chrome)" >&2
  exit 1
fi

"$CHROME" \
  --headless \
  --disable-gpu \
  --hide-scrollbars \
  --allow-file-access-from-files \
  --force-device-scale-factor=1 \
  --window-size=1200,630 \
  --virtual-time-budget=5000 \
  --screenshot="$OUT" \
  "file://$SRC" 2>/dev/null

echo "▸ Wrote $OUT ($(sips -g pixelWidth -g pixelHeight "$OUT" | tail -2 | tr -d ' \n'))"
echo "  Next: node scripts/sync-assets.mjs   # copy it into apps/site/public/og.png"
