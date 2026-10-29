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
