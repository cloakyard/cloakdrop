#!/usr/bin/env bash
# Build apps/site first; then render the shared Air card from its static landing artwork.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
export CHROME_PATH="${CHROME_PATH:-${CHROME:-}}"
exec node "$REPO/docs/air/render-social.mjs"
