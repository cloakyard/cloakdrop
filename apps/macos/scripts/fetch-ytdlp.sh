#!/usr/bin/env bash
#
# fetch-ytdlp.sh — vendor the yt-dlp "onedir" bundle (unpacked Python runtime) for CloakDrop.
#
# yt-dlp is CloakDrop's decipher/enumerate ORACLE, not its downloader: given a page URL it returns the
# real, deciphered video/audio format tiers (with the HTTP headers to fetch them), which CloakDrop's
# own multi-segment engine then downloads and muxes. yt-dlp never opens the destination file — it only
# resolves — so pause/resume, segmentation, and the sandbox story stay ours.
#
# Why the ONEDIR build (yt-dlp_macos.zip), not the single-file one: the PyInstaller *onefile* binary
# self-extracts its Python runtime to a temp dir on every launch and coordinates that with a SysV
# semaphore. Inside CloakDrop's App Sandbox both are blocked — the semaphore is denied ("semctl:
# Operation not permitted") and loading code from the writable temp is "disallowed by system policy",
# with Gatekeeper flagging the extracted framework as damaged. The onedir build ships the runtime
# UNPACKED next to the executable (in `_internal/`), so it loads from a fixed, read-only, code-signed
# location — no extraction, no semaphore, no Gatekeeper prompt — and starts in ~0.5s.
#
# The tree lands at Vendor/yt-dlp/{yt-dlp,_internal} (git-ignored). project.yml's "Bundle & sign
# yt-dlp" phase copies+signs it into CloakDrop.app on the next build; without it, page-URL grabs report
# the extractor unavailable (the rest of the app is unaffected).
#
# Staying current: YouTube changes often — bump YTDLP_VERSION + YTDLP_SHA256 periodically and rebuild.
#
# Usage:
#   scripts/fetch-ytdlp.sh                     # vendor the pinned version (arm64)
#   YTDLP_SHA256="" scripts/fetch-ytdlp.sh     # print the downloaded hash and stop (how a bump is verified)
#
set -euo pipefail

# --- Pinned release ----------------------------------------------------------------------------
YTDLP_VERSION="2026.07.04"
YTDLP_URL="https://github.com/yt-dlp/yt-dlp/releases/download/${YTDLP_VERSION}/yt-dlp_macos.zip"
# SHA-256 of the official yt-dlp_macos.zip (onedir) for the pinned version. Cross-check against the
# release's SHA2-256SUMS before trusting a bump. Set YTDLP_SHA256="" to print the hash and stop.
YTDLP_SHA256="${YTDLP_SHA256:-b0724470a0cf6dae5175a87eee05d6e75c5a0c10d2c3015166bd4d34e92b1b7b}"

# --- Paths -------------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/Vendor/yt-dlp"
BUILD_DIR="${VENDOR_DIR}/build"
mkdir -p "${BUILD_DIR}"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -m)" = "arm64" ] || fail "CloakDrop ships Apple Silicon only; run this on an arm64 Mac (got $(uname -m))."
command -v lipo >/dev/null 2>&1 || fail "lipo is required (Xcode Command Line Tools: xcode-select --install)."

# --- Download & verify -------------------------------------------------------------------------
DL="${BUILD_DIR}/yt-dlp_macos-${YTDLP_VERSION}.zip"
if [ ! -f "${DL}" ]; then
  info "Downloading yt-dlp ${YTDLP_VERSION} (onedir, ~51 MB)"
  curl -fL --retry 3 -o "${DL}" "${YTDLP_URL}"
fi

ACTUAL_SHA="$(shasum -a 256 "${DL}" | awk '{print $1}')"
if [ -z "${YTDLP_SHA256}" ]; then
  cat >&2 <<EOF

$(info "Downloaded yt-dlp_macos.zip SHA-256:")
    ${ACTUAL_SHA}

Cross-check this against the SHA2-256SUMS on the release
(https://github.com/yt-dlp/yt-dlp/releases/tag/${YTDLP_VERSION}), then pin it (YTDLP_SHA256 at the
top of this script) and re-run. Refusing to vendor an unverified binary.
EOF
  exit 1
fi
[ "${ACTUAL_SHA}" = "${YTDLP_SHA256}" ] || fail "checksum mismatch: expected ${YTDLP_SHA256}, got ${ACTUAL_SHA}"
info "Checksum verified"

# --- Unpack ------------------------------------------------------------------------------------
# The zip contains `yt-dlp_macos` (the executable) + `_internal/` (Python runtime + deps).
STAGE="${BUILD_DIR}/unzipped"
rm -rf "${STAGE}"; mkdir -p "${STAGE}"
unzip -q "${DL}" -d "${STAGE}"
[ -f "${STAGE}/yt-dlp_macos" ] && [ -d "${STAGE}/_internal" ] || fail "unexpected archive layout (no yt-dlp_macos + _internal)"
rm -rf "${VENDOR_DIR}/yt-dlp" "${VENDOR_DIR}/_internal"
mv "${STAGE}/yt-dlp_macos" "${VENDOR_DIR}/yt-dlp"
mv "${STAGE}/_internal" "${VENDOR_DIR}/_internal"
rm -rf "${STAGE}"
chmod +x "${VENDOR_DIR}/yt-dlp"

# --- Thin universal2 → arm64 -------------------------------------------------------------------
# CloakDrop bundles no x86_64, and thinning ~halves the vendored size. Best-effort: a missed file
# just stays universal (still runs on arm64), so correctness never depends on it. `-type f` skips the
# framework's symlinks (thinning one would replace the link with a file and break the structure).
info "Thinning universal2 → arm64 (touches ~100 runtime files)"
thin_one() {
  local f="$1" archs
  archs="$(lipo -archs "$f" 2>/dev/null)" || return 0
  case "$archs" in *arm64*) ;; *) return 0 ;; esac
  [ "$(echo "$archs" | wc -w)" -gt 1 ] || return 0
  lipo -thin arm64 "$f" -output "$f.thin" 2>/dev/null && mv "$f.thin" "$f"
}
thin_one "${VENDOR_DIR}/yt-dlp"
while IFS= read -r -d '' f; do thin_one "$f"; done \
  < <(find "${VENDOR_DIR}/_internal" -type f \( -name "*.so" -o -name "*.dylib" -o -name "Python" \) -print0)

# --- Normalize framework layout ----------------------------------------------------------------
# PyInstaller ships Python.framework with real files where a framework needs versioned SYMLINKS
# (top-level Python/Resources, and Versions/Current). codesign rejects that as "bundle format is
# ambiguous", which fails CloakDrop's app seal. Rebuild the canonical structure (this also de-dups
# the ~7 MB Python binary that was copied to the top level).
info "Normalizing framework layout"
fix_framework() {
  local fw="$1" ver entry name
  ver="$(ls "$fw/Versions" 2>/dev/null | grep -vx Current | head -1)"
  [ -n "$ver" ] || return 0
  ( cd "$fw/Versions" && rm -rf Current && ln -s "$ver" Current )
  for entry in "$fw/Versions/Current"/*; do
    name="$(basename "$entry")"
    ( cd "$fw" && rm -rf "$name" && ln -s "Versions/Current/$name" "$name" )
  done
}
while IFS= read -r -d '' fw; do fix_framework "$fw"; done \
  < <(find "${VENDOR_DIR}/_internal" -type d -name "*.framework" -print0)

# --- Ad-hoc sign the tree ----------------------------------------------------------------------
# For local (Debug) runs; the app's build phase re-signs with your identity for release. Deepest-first:
# nested dylibs, then the Python framework, then the executable (thinning invalidated signatures, so
# re-signing is required for the tree to load).
info "Ad-hoc signing the vendored tree"
find "${VENDOR_DIR}/_internal" -type f \( -name "*.so" -o -name "*.dylib" \) -exec codesign --force --sign - {} + 2>/dev/null || true
[ -d "${VENDOR_DIR}/_internal/Python.framework" ] && codesign --force --deep --sign - "${VENDOR_DIR}/_internal/Python.framework" 2>/dev/null || true
codesign --force --sign - "${VENDOR_DIR}/yt-dlp"

info "Vendored $(du -sh "${VENDOR_DIR}" | grep -v build | awk '{print $1}') (arm64) → Vendor/yt-dlp/{yt-dlp,_internal}"
info "Sanity check:"; "${VENDOR_DIR}/yt-dlp" --version 2>&1 | sed 's/^/    yt-dlp /'
info "Done. Rebuild CloakDrop to bundle it (project.yml's \"Bundle & sign yt-dlp\" phase)."
