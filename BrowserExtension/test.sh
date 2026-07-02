#!/usr/bin/env bash
# Run the extension's zero-dependency unit tests (Node's built-in runner — no npm install).
# Node's --test dislikes a bare directory argument, so we expand the file list explicitly.
set -euo pipefail
cd "$(dirname "$0")"
exec node --test tests/*.test.js
