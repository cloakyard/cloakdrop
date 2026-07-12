# Vendored ffmpeg

This directory holds the optional bundled `ffmpeg` binary that lets CloakDrop mux the codecs
AVFoundation can't carry — VP9/AV1 video and Opus audio (YouTube WebM, high-resolution adaptive
renditions) — into a clean `.mkv`. See [`FFmpegMuxer`](../../Packages/DownloaderCore/Sources/DownloadEngine/FFmpegMuxer.swift).

**The binary (`ffmpeg`) and its `build/` scratch are git-ignored** — they're multi-megabyte build
artifacts, not source. Produce them with:

```bash
scripts/fetch-ffmpeg.sh          # builds a minimal, LGPL, network-free static ffmpeg → ./ffmpeg
```

Then rebuild CloakDrop: the app target's *"Bundle & sign ffmpeg"* build phase copies and re-signs
`./ffmpeg` into `CloakDrop.app/Contents/MacOS/ffmpeg`, where `FFmpegMuxer.locate()` finds it at
runtime. **Without this binary the app still works** — it just falls back to AVFoundation
(H.264/HEVC + AAC), and grabs of the exotic codecs ship video-only.

The build is stream-copy-only (LGPL, no encoders, no network) — see the header of
`scripts/fetch-ffmpeg.sh` for the rationale and the exact `configure` flags.
