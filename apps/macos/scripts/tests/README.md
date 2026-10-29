# Live media smoke checks

`LiveMediaSmokeTests` is opt-in. Ordinary `swift test` never runs this live-site
check. It resolves public pages with the bundled yt-dlp, transfers through the real
engine/URLSession, packages with AVFoundation and the bundled FFmpeg, then checks
track types, durations, packet counts, audio classification, and full decoding.
Its in-memory catalog never touches the app's downloads or statistics.

Create a JSON array in a private temporary directory, for example:

```json
[{
  "name": "youtube-mp4",
  "url": "https://www.youtube.com/watch?v=7zfir0Ide0A",
  "mode": "mp4",
  "expectedDuration": 44.49,
  "maxHeight": 720,
  "expectVideo": true,
  "expectAudio": true,
  "expectedVideoPackets": 1333,
  "expectedAudioPackets": 1916
}]
```

Modes are `mp4`, `original`, or `audio`. Optional expected packet counts catch silent
frame loss that duration and full decoding alone can miss; derive them from source
evidence for the selected rendition. Use a fresh output directory for each run.
The source duration is a checked expectation, not a requested trim. Site responses
can change; an extraction/access/protection failure is not a successful transfer.
The bounded check times out each transfer after 180 seconds. Choose short VOD
samples and a modest maximum quality; this downloads the complete selected media.

From the repository root (adjust the external probe/decoder paths if needed):

```sh
GIT_CONFIG_COUNT=0 \
CLOAKDROP_LIVE_MEDIA_CONFIG=/tmp/media-smoke/cases.json \
CLOAKDROP_LIVE_MEDIA_OUTPUT=/tmp/media-smoke/results \
YTDLP_PATH="$PWD/apps/macos/Vendor/yt-dlp/yt-dlp" \
FFMPEG_PATH="$PWD/apps/macos/Vendor/ffmpeg/ffmpeg" \
FFPROBE_PATH=/opt/homebrew/bin/ffprobe \
MEDIA_DECODER_PATH=/opt/homebrew/bin/ffmpeg \
swift test --package-path apps/macos/Packages/DownloaderCore --filter LiveMediaSmokeTests
```

Use the vendor helper for packaging. The full decoder is a verification-only tool;
it is not bundled or a new application dependency. The app's signed `inherit`
helper cannot be launched standalone from an unsandboxed shell.

Failures and resolved media may contain expiring CDN URLs. Keep failure artifacts
private; commit only scrubbed summaries, probe JSON without source URLs, and screenshots
that exclude credentials and unrelated records. Delete disposable test output after review.

See [the October multi-site audit](../../../../docs/audits/2026-10-29-multisite.md)
for tested URLs, observed results, helper fingerprint and limitations.
