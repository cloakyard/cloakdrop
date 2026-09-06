#!/usr/bin/env bash
#
# fetch-ffmpeg.sh — build a minimal, LGPL, network-free static `ffmpeg` for CloakDrop.
#
# CloakDrop only ever *stream-copies* (`ffmpeg -c copy`) an adaptive stream's separate video and
# audio into one Matroska file — it never re-encodes. So this build:
#
#   • is LGPL-only (`--disable-gpl --disable-nonfree`) — no x264/x265/libfdk, which are the
#     GPL/nonfree *encoders* we never call — so the binary is safe to ship in a Developer-ID app;
#   • disables encoders, decoders, hardware acceleration, and every nonessential filter —
#     stream-copy only needs demuxers, muxers, and the CLI's small required filter primitives;
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
# Pin a specific release so the build is reproducible. Verify its detached PGP signature with the
# release key published at https://ffmpeg.org/download.html before trusting and pinning its hash.
FFMPEG_VERSION="9.0.1"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
# Pinned SHA-256 of the PGP-verified ffmpeg-9.0.1.tar.xz from ffmpeg.org. Override per-run with the
# FFMPEG_SHA256 env var; set it to "" to have the script print the downloaded hash and stop (how a
# new version gets verified).
FFMPEG_SHA256="${FFMPEG_SHA256-cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635}"

# --- Paths -------------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/Vendor/ffmpeg"
BUILD_DIR="${VENDOR_DIR}/build"
OUTPUT="${VENDOR_DIR}/ffmpeg"

mkdir -p "${BUILD_DIR}"
DOWNLOAD_TEMP=""
OUTPUT_TEMP=""
cleanup() {
  [ -z "${DOWNLOAD_TEMP}" ] || rm -f "${DOWNLOAD_TEMP}"
  [ -z "${OUTPUT_TEMP}" ] || rm -f "${OUTPUT_TEMP}"
}
trap cleanup EXIT

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v xcrun >/dev/null 2>&1 || fail "Xcode Command Line Tools are required (xcode-select --install)."
[ "$(uname -m)" = "arm64" ] || fail "This builds arm64 only and must run on Apple Silicon (got $(uname -m))."

# --- Download & verify -------------------------------------------------------------------------
TARBALL="${BUILD_DIR}/ffmpeg-${FFMPEG_VERSION}.tar.xz"
if [ ! -f "${TARBALL}" ]; then
  info "Downloading ffmpeg ${FFMPEG_VERSION}"
  DOWNLOAD_TEMP="$(mktemp "${TARBALL}.download.XXXXXX")"
  curl --proto '=https' --proto-redir '=https' -fL --retry 3 -o "${DOWNLOAD_TEMP}" "${FFMPEG_URL}"
  mv "${DOWNLOAD_TEMP}" "${TARBALL}"
  DOWNLOAD_TEMP=""
fi

ACTUAL_SHA="$(shasum -a 256 "${TARBALL}" | awk '{print $1}')"
if [ -z "${FFMPEG_SHA256}" ]; then
  cat >&2 <<EOF

$(info "Downloaded tarball SHA-256:")
    ${ACTUAL_SHA}

Verify the tarball against its detached signature and the release key published at
https://ffmpeg.org/download.html, then pin this hash — set FFMPEG_SHA256 at the top of this script
(or export it) — and re-run. Refusing to build an unverified source tarball.
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
# Minimal, LGPL, remux-only, no network. Probing is handled by demuxers, so stream-copy needs no
# codecs or hardware accelerators; ffmpeg retains only its CLI-required filter primitives. Only
# file/pipe/fd protocols are available.
COMMON_FLAGS=(
  --disable-gpl --disable-nonfree           # LGPL only — no GPL/nonfree components in the binary
  --disable-autodetect                     # installed Homebrew libraries must not alter this build
  --enable-zlib --enable-bzlib --enable-iconv # explicitly retain only system compression/text libs
  --extra-libs=-liconv                     # macOS iconv is separate from libc when autodetect is off
  --disable-doc
  --disable-programs --enable-ffmpeg        # ship only the `ffmpeg` CLI, nothing else
  --disable-network                         # privacy: the helper cannot open a socket
  --disable-protocols --enable-protocol=file,pipe,fd
  --disable-avdevice --disable-devices      # no capture/render devices
  --disable-encoders --disable-decoders     # we only stream-copy — never transform media payloads
  --disable-filters                         # retain only the primitives the ffmpeg CLI selects
  --disable-hwaccels                        # hardware acceleration only pulls decoders back in
  # These legacy demuxers/parser are irrelevant to supported web-media containers and emit warnings
  # under the current Apple Clang. Keeping them out also trims dead format code from the helper.
  --disable-demuxer=jv --disable-demuxer=nsp --disable-demuxer=nuv
  --disable-parser=lcevc
  --enable-static --disable-shared          # no third-party dylibs → passes Library Validation
  --enable-small
  --disable-debug
)

# --- Build (arm64 — CloakDrop is Apple Silicon only) -------------------------------------------
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
OUTPUT_TEMP="$(mktemp "${OUTPUT}.build.XXXXXX")"
cp -f "${BUILD_DIR}/out/bin/ffmpeg" "${OUTPUT_TEMP}"

strip -S "${OUTPUT_TEMP}"
chmod +x "${OUTPUT_TEMP}"

# Ad-hoc sign for local (Debug) runs; the app's build phase re-signs with your identity for release.
codesign --force --sign - "${OUTPUT_TEMP}"
codesign --verify --strict "${OUTPUT_TEMP}"
[ "$(lipo -archs "${OUTPUT_TEMP}")" = "arm64" ] || fail "ffmpeg must contain only arm64 code."
UNEXPECTED_LIBRARIES="$(otool -L "${OUTPUT_TEMP}" | tail -n +2 | awk '{print $1}' | \
  sed '/^\/usr\/lib\//d; /^\/System\/Library\//d')"
[ -z "${UNEXPECTED_LIBRARIES}" ] || fail "ffmpeg links non-system libraries: ${UNEXPECTED_LIBRARIES}"
ACTUAL_VERSION="$("${OUTPUT_TEMP}" -version 2>/dev/null | sed -n '1s/^ffmpeg version \([^ ]*\).*/\1/p')"
[ "${ACTUAL_VERSION}" = "${FFMPEG_VERSION}" ] || fail "unexpected ffmpeg version: ${ACTUAL_VERSION}"
# Publish only after the complete binary has passed signing, architecture, and linkage checks.
mv -f "${OUTPUT_TEMP}" "${OUTPUT}"
OUTPUT_TEMP=""

info "Built $(du -h "${OUTPUT}" | awk '{print $1}') → ${OUTPUT#${REPO_ROOT}/}"
info "Linked libraries (should be system-only — no third-party dylibs):"
otool -L "${OUTPUT}" | sed 's/^/    /'
info "Done. Rebuild CloakDrop to bundle it (project.yml's \"Bundle & sign ffmpeg\" phase)."
