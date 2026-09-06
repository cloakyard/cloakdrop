# Vendored FFmpeg

This directory holds the optional bundled `ffmpeg` binary that lets CloakDrop mux the codecs
AVFoundation can't carry — VP9/AV1 video and Opus audio (YouTube WebM, high-resolution adaptive
renditions) — into a clean `.mkv`. See [`FFmpegMuxer`](../../Packages/DownloaderCore/Sources/DownloadEngine/FFmpegMuxer.swift).

The binary (`ffmpeg`) and its `build/` directory are git-ignored. Build on an Apple Silicon Mac
with the Xcode command-line tools installed, from `apps/macos/`:

```bash
scripts/fetch-ffmpeg.sh
```

The [fetch script](../../scripts/fetch-ffmpeg.sh) is the source of truth for the version,
source URL, SHA-256, and complete configure flags. It currently builds **FFmpeg 9.0.1** for
arm64 with a macOS 26 deployment target and writes `Vendor/ffmpeg/ffmpeg`.

Rebuild CloakDrop afterward. The [project build phase](../../project.yml) copies the helper to
`CloakDrop.app/Contents/MacOS/ffmpeg`, signs it with sandbox-inheritance entitlements, and verifies
the signature. It removes a stale bundled helper when the vendor binary is absent.
Without this binary the app still works: AVFoundation handles compatible H.264/HEVC
and AAC media. Unsupported single-stream input is kept in its original container; a split video/audio
rendition can finish video-only when no available muxer accepts its codecs.

## Build configuration and verification

- `--disable-gpl --disable-nonfree`: no optional GPL/nonfree components.
- `--disable-autodetect`: installed Homebrew libraries do not silently change the build.
  System zlib, bzip2, and iconv are explicitly enabled, with `--extra-libs=-liconv`.
- `--disable-network --disable-protocols --enable-protocol=file,pipe,fd`: local input/output only.
- Encoders, decoders, hardware acceleration, devices, and optional filters are disabled.
  FFmpeg retains its required CLI filter primitives and remuxes with stream copy.
- FFmpeg's own libraries are statically linked into the executable (`--enable-static
  --disable-shared`). **The executable still links macOS system libraries/frameworks**;
  it is not a completely static binary. No third-party dynamic library is accepted.

The script requires HTTPS for downloads and redirects and checks the pinned source hash before
extracting. An empty `FFMPEG_SHA256` prints the downloaded hash and stops; it does not bypass
verification. Before publishing the completed binary, the script checks its ad-hoc signature,
arm64 architecture, release version, and system-only linkage. Failed preparation leaves the
existing helper in place. Run vendor scripts without a concurrent app build.

For a version bump, verify the source archive's detached signature with the release key from
[FFmpeg's official download page](https://ffmpeg.org/download.html) before updating the pin.
The script does not perform GPG verification on each run. See the
[dependency audit](../../../../docs/audits/2026-09-06-dependencies.md) for the verified fingerprints,
hashes, linkage checks, and actual H.264/AAC, VP9/Opus, and AV1/Opus mux results. Builds pin source
and configuration; byte-identical output across different SDK/compiler versions is not promised.

## Licensing and distribution

This configuration uses FFmpeg under LGPL 2.1 or later. CloakDrop invokes the separate executable;
it does not link its Swift targets against FFmpeg. CloakDrop's MIT license does not replace the
helper's license. When distributing the helper, include its license/notices and provide the exact
corresponding FFmpeg source and build configuration, including any modifications. Disabling GPL
and nonfree components does not remove redistribution obligations; follow
[FFmpeg's licensing guidance](https://ffmpeg.org/legal.html).

Local ad-hoc signing is distinct from Developer ID signing and Apple notarization. The current
beta is locally signed and not notarized; see the [security policy](../../../../SECURITY.md).
