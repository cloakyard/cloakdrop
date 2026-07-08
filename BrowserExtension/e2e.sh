#!/usr/bin/env bash
# End-to-end smoke of the built extension in a real Chromium: loads dist/chrome into a cached
# Chrome for Testing (branded Chrome blocks CLI sideload), serves a crafted page that exercises
# every detection path, and asserts the deduped list, the single in-page pill, and the
# interception → bypass re-download safety net. Zero npm dependencies (raw CDP over Node's
# built-in WebSocket; needs Node ≥ 22).
#
# Chrome for Testing is discovered from $CHROME_BIN, the puppeteer cache, or the Playwright cache.
set -euo pipefail
cd "$(dirname "$0")"

CHROME="${CHROME_BIN:-}"
if [[ -z "$CHROME" ]]; then
  # Newest puppeteer-cached build first (glob sorts ascending, so the last match is newest);
  # the Playwright chromium is only a fallback — older builds mishandle extensions in headless.
  for candidate in \
    "$HOME/.cache/puppeteer/chrome"/*/chrome-mac-arm64/"Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"; do
    [[ -x "$candidate" ]] && CHROME="$candidate"
  done
  if [[ -z "$CHROME" ]]; then
    for candidate in \
      "$HOME/Library/Caches/ms-playwright"/chromium-*/chrome-mac-arm64/"Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"; do
      [[ -x "$candidate" ]] && CHROME="$candidate"
    done
  fi
fi
[[ -x "${CHROME:-}" ]] || { echo "error: no Chrome for Testing found — set CHROME_BIN"; exit 1; }

./package.sh >/dev/null

PORT=8877
python3 tests/e2e/server.py "$PORT" & SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT
sleep 1

node tests/e2e/e2e.mjs "$CHROME" "$(pwd)/dist/chrome" "$PORT"
