#!/usr/bin/env bash
#
# fetch-ffmpeg.sh — build a minimal, LGPL, network-free static `ffmpeg` for CloakDrop.
#
# CloakDrop only ever *stream-copies* (`ffmpeg -c copy`) an adaptive stream's separate video and
# audio into one Matroska file — it never re-encodes. So this build:
#
#   • is LGPL-only (`--disable-gpl --disable-nonfree`) — no x264/x265/libfdk, which are the
#     GPL/nonfree *encoders* we never call — so the binary is safe to ship in a Developer-ID app;
#   • disables all encoders (`--disable-encoders`) — nothing to encode when copying;
#   • disables network and non-file protocols — a privacy-first app's helper must not be able to
#     open a socket. It reads local part files and writes a local `.mkv`, nothing else;
#   • is fully static (`--disable-shared`) — no third-party dylibs, so it passes Library Validation
#     under the hardened runtime and needs no @rpath wrangling.
#
# The result lands at Vendor/ffmpeg/ffmpeg (git-ignored). project.yml's "Bundle & sign ffmpeg"
# build phase copies+signs it into CloakDrop.app/Contents/MacOS on the next build; without it the
# app just falls back to AVFoundation (H.264/HEVC + AAC only).
#
# CloakDrop ships Apple Silicon only, so this builds an arm64 binary and must run on Apple Silicon.
#
# Usage:
#   scripts/fetch-ffmpeg.sh                       # build the arm64 (Apple Silicon) binary
#   FFMPEG_SHA256=<hash> scripts/fetch-ffmpeg.sh  # override/verify the source tarball checksum
#
set -euo pipefail

# --- Pinned source -----------------------------------------------------------------------------
# Pin a specific release so the build is reproducible. Verify the checksum against the value
# published at https://ffmpeg.org/download.html (and ideally the GPG signature) before trusting it.
FFMPEG_VERSION="7.1"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
# Pinned SHA-256 of ffmpeg-7.1.tar.xz, cross-checked against the identical value Debian and
# OpenEmbedded/Yocto pin for the same tarball. Override per-run with the FFMPEG_SHA256 env var; set
# it to "" to have the script print the downloaded hash and stop (how a new version gets verified).
FFMPEG_SHA256="${FFMPEG_SHA256:-40973d44970dbc83ef302b0609f2e74982be2d85916dd2ee7472d30678a7abe6}"

# --- Paths -------------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/Vendor/ffmpeg"
BUILD_DIR="${VENDOR_DIR}/build"
OUTPUT="${VENDOR_DIR}/ffmpeg"

mkdir -p "${BUILD_DIR}"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v xcrun >/dev/null 2>&1 || fail "Xcode Command Line Tools are required (xcode-select --install)."

# --- Download & verify -------------------------------------------------------------------------
TARBALL="${BUILD_DIR}/ffmpeg-${FFMPEG_VERSION}.tar.xz"
if [ ! -f "${TARBALL}" ]; then
  info "Downloading ffmpeg ${FFMPEG_VERSION}"
  curl -fL --retry 3 -o "${TARBALL}" "${FFMPEG_URL}"
fi

ACTUAL_SHA="$(shasum -a 256 "${TARBALL}" | awk '{print $1}')"
if [ -z "${FFMPEG_SHA256}" ]; then
  cat >&2 <<EOF

$(info "Downloaded tarball SHA-256:")
    ${ACTUAL_SHA}

Verify this against the checksum/signature published at https://ffmpeg.org/download.html, then pin
it — set FFMPEG_SHA256 at the top of this script (or export it) — and re-run. Refusing to build an
unverified source tarball.
EOF
  exit 1
fi
[ "${ACTUAL_SHA}" = "${FFMPEG_SHA256}" ] || fail "checksum mismatch: expected ${FFMPEG_SHA256}, got ${ACTUAL_SHA}"
info "Checksum verified"

SRC_DIR="${BUILD_DIR}/ffmpeg-${FFMPEG_VERSION}"
rm -rf "${SRC_DIR}"
info "Extracting"
tar -xf "${TARBALL}" -C "${BUILD_DIR}"

# --- Configure flags (shared across architectures) ---------------------------------------------
# Minimal, LGPL, remux-only, no network. Decoders/avfilter are kept (the ffmpeg CLI links avfilter;
# decoders cost little and keep probing robust) — they're all LGPL. Only file/pipe/fd protocols.
COMMON_FLAGS=(
  --disable-gpl --disable-nonfree           # LGPL only — no GPL/nonfree components in the binary
  --disable-doc
  --disable-programs --enable-ffmpeg        # ship only the `ffmpeg` CLI, nothing else
  --disable-network                         # privacy: the helper cannot open a socket
  --disable-protocols --enable-protocol=file,pipe,fd
  --disable-avdevice --disable-devices      # no capture/render devices
  --disable-encoders                        # we only stream-copy — never encode
  --enable-static --disable-shared          # no third-party dylibs → passes Library Validation
  --enable-small
  --disable-debug
)

# --- Build (arm64 — CloakDrop is Apple Silicon only) -------------------------------------------
[ "$(uname -m)" = "arm64" ] || fail "This builds arm64 only and must run on Apple Silicon (got $(uname -m))."

SDK="$(xcrun --sdk macosx --show-sdk-path)"
info "Configuring (arm64)"
( cd "${SRC_DIR}" && ./configure \
    "${COMMON_FLAGS[@]}" \
    --cc="xcrun --sdk macosx clang -arch arm64" \
    --extra-cflags="-arch arm64 -isysroot ${SDK} -mmacosx-version-min=26.0" \
    --extra-ldflags="-arch arm64 -isysroot ${SDK} -mmacosx-version-min=26.0" \
    --prefix="${BUILD_DIR}/out" >/dev/null )
info "Building (arm64) — this takes a few minutes"
( cd "${SRC_DIR}" && make -j"$(sysctl -n hw.ncpu)" >/dev/null && make install >/dev/null )
cp -f "${BUILD_DIR}/out/bin/ffmpeg" "${OUTPUT}"

strip -S "${OUTPUT}" || true
chmod +x "${OUTPUT}"

# Ad-hoc sign for local (Debug) runs; the app's build phase re-signs with your identity for release.
codesign --force --sign - "${OUTPUT}"

info "Built $(du -h "${OUTPUT}" | awk '{print $1}') → ${OUTPUT#${REPO_ROOT}/}"
info "Linked libraries (should be system-only — no third-party dylibs):"
otool -L "${OUTPUT}" | sed 's/^/    /'
info "Done. Rebuild CloakDrop to bundle it (project.yml's \"Bundle & sign ffmpeg\" phase)."
