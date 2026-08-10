# Vendored ffmpeg

This directory holds the optional bundled `ffmpeg` binary that lets CloakDrop mux the codecs
AVFoundation can't carry — VP9/AV1 video and Opus audio (YouTube WebM, high-resolution adaptive
renditions) — into a clean `.mkv`. See [`FFmpegMuxer`](../../Packages/DownloaderCore/Sources/DownloadEngine/FFmpegMuxer.swift).

**The binary (`ffmpeg`) and its `build/` scratch are git-ignored** — they're multi-megabyte build
artifacts, not source. Produce them from `apps/macos/` with:

```bash
scripts/fetch-ffmpeg.sh          # builds a minimal, LGPL, network-free static ffmpeg → ./ffmpeg
```

Then rebuild CloakDrop: the app target's *"Bundle & sign ffmpeg"* build phase copies and re-signs
`./ffmpeg` into `CloakDrop.app/Contents/MacOS/ffmpeg`, where `FFmpegMuxer.locate()` finds it at
runtime. **Without this binary the app still works** — AVFoundation handles compatible H.264/HEVC
and AAC media. Unsupported single-stream input is kept in its original container; a split video/audio
rendition can finish video-only when no available muxer accepts its codecs.

The build is stream-copy-only (LGPL, no encoders, no network) — see the header of
`scripts/fetch-ffmpeg.sh` for the rationale and the exact `configure` flags.
