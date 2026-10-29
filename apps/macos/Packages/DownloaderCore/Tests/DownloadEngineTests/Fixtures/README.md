# AV1 timing regression

`av1-30fps.mp4` is a synthetic blue 64 × 64 video: 30 AV1 frames over one second,
without audio. It contains no downloaded content. Generated with FFmpeg/SVT-AV1:

```sh
ffmpeg -f lavfi -i 'color=c=blue:s=64x64:r=30:d=1' \
  -c:v libsvtav1 -preset 12 -crf 40 -an av1-30fps.mp4
```

Keep the fixture so the native rejection regression runs without an AV1 encoder
or network. Apple can report a successful passthrough export for AV1 while
changing its sample timing; MP4 container recognition is insufficient.

## Fragmented H.264 timing

`h264-fragmented.mp4` is a synthetic blue 64 × 64 video with 30 H.264 frames over
one second. It contains no downloaded content. Generated using the system encoder:

```sh
ffmpeg -f lavfi -i 'color=c=blue:s=64x64:r=30:d=1' \
  -c:v h264_videotoolbox -b:v 50k -an \
  -movflags frag_keyframe+empty_moov h264-fragmented.mp4
```

This exercises the fragmented-container fallback independently of codecs. Apple's
reader doubles the reported duration of the real YouTube H.264 input in the
2026-10-29 MP4 audit, so comparing an export against AVAsset's own duration would
not catch the corruption. The synthetic fixture verifies dispatch, packet count
and duration through FFmpeg; the audit supplies the observed real-file evidence.
