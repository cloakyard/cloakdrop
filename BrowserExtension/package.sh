#!/usr/bin/env bash
# Assemble the per-browser CloakDrop extension folders from the single shared source.
#
# A loadable WebExtension needs its manifest to be named exactly `manifest.json`, so we can't keep
# Chrome and Firefox manifests side by side in one loadable directory. Instead the shared assets
# (background.js, popup.html, icons) live in shared/, the two manifests live at the root, and this
# script stitches them into dist/chrome and dist/firefox (and zips them for distribution).
#
# Usage:
#   ./package.sh          # build dist/chrome and dist/firefox
#   ./package.sh --zip    # also produce dist/cloakdrop-chrome.zip and dist/cloakdrop-firefox.zip
set -euo pipefail
cd "$(dirname "$0")"

DIST="dist"
rm -rf "$DIST"
mkdir -p "$DIST/chrome" "$DIST/firefox"

build() {
  local browser="$1"
  local manifest="$2"
  local out="$DIST/$browser"
  cp shared/* "$out/"
  cp "$manifest" "$out/manifest.json"
  # Fail loudly on a malformed manifest rather than shipping a broken folder.
  python3 -c "import json,sys; json.load(open('$out/manifest.json'))" \
    || { echo "error: $manifest is not valid JSON"; exit 1; }
  echo "built $out"
}

build chrome  manifest.chrome.json
build firefox manifest.firefox.json

# The Safari Web Extension bundles the SAME shared assets (its manifest stays its own, inside the
# Xcode target). It can't reference shared/ directly, so keep its copies in lockstep here — drift
# means Safari silently ships an older extension than Chrome/Firefox.
SAFARI="../SafariExtension/WebExtension"
if [[ -d "$SAFARI" ]]; then
  find shared -maxdepth 1 -type f ! -name "manifest*" -exec cp {} "$SAFARI/" \;
  # Safari keeps its own hand-maintained manifest (content_scripts/permissions must stay in lockstep
  # with the chrome/firefox ones). Validate it so a drift/typo fails loudly instead of shipping broken.
  python3 -c "import json; json.load(open('$SAFARI/manifest.json'))" \
    || { echo "error: $SAFARI/manifest.json is not valid JSON"; exit 1; }
  echo "synced $SAFARI"
fi

if [[ "${1:-}" == "--zip" ]]; then
  ( cd "$DIST/chrome"  && zip -qr "../cloakdrop-chrome.zip"  . )
  ( cd "$DIST/firefox" && zip -qr "../cloakdrop-firefox.zip" . )
  echo "zipped dist/cloakdrop-chrome.zip and dist/cloakdrop-firefox.zip"
fi
