# Multi-site media verification — October 29, 2026

Tested the YouTube/MP4 changes against YouTube, Dailymotion, SoundCloud and Vimeo,
using the native Debug app and an opt-in real-engine smoke suite. This audit covers
these specific public samples and local failure/recovery tests; it does not certify
every video or site supported by yt-dlp.

## Regressions found and fixed

- **Audio saved as video:** fragmented AAC fell through to FFmpeg's general MKV
  output. Audio-only requests now persist `.originalAudio`, reserve an audio
  filename, use M4A or MKA stream-copy and reject video-classified publication.
  SoundCloud's codec-less HLS playlist retains explicit audio-only evidence from
  its page extraction. The picker presents “Download Audio” instead of “Video”.
- **HLS MP4 unavailable:** compatible HLS variants now offer MP4 when CODECS declares
  H.264/AAC-LC and the referenced audio group exists. Unknown codecs, HEVC/HE-AAC
  and missing groups are not treated as evidence of compatibility. The actual
  copied MP4 is validated before publication; no transcoding was added.
- **Bundled AAC probing:** MPEG-TS AAC can require a decoder to discover channel
  count/sample rate. The minimal FFmpeg build now retains its native AAC decoder
  for probing. All encoders remain disabled and all outputs use stream-copy.
- **Silent MPEG-TS packet loss:** Apple's exporter produced a plausible-duration,
  decodable 288p Dailymotion MP4 with only 5,540 video packets and 4,017 audio packets.
  The source rendition contains 5,597/4,019. MPEG-TS now bypasses AVFoundation, by
  extension and bounded packet-sync inspection (including mislabeled `.mp4`).
  FFmpeg preserves all 5,597/4,019 packets. Exact packet expectations supplement
  full decoding and duration checks in the live suite.
- **Audio groups:** HLS quality changes only offer audio tracks from that quality's
  AUDIO group. Identical language/name labels receive stable ordinals in audio-only
  mode. DASH/extracted language alternatives remain selectable.

## Live sample results

All successful cases below were transferred by `DownloadManager`/URLSession,
packaged with AVFoundation plus the actual vendor FFmpeg fallback, inspected with
FFprobe, and fully decoded with `ffmpeg -v error -xerror ... -f null -` (exit 0).
The full decoder is a local verification tool, not a new application dependency.
Packet counts are checked against the observed source renditions.

| Public page | Mode | Result | Duration | Video/audio packets |
| --- | --- | --- | --- | --- |
| [YouTube: reported clip](https://www.youtube.com/watch?v=7zfir0Ide0A) | Compatible MP4, 720p | H.264 + AAC, MP4 | 44.489433 s | 1,333 / 1,916 |
| Same YouTube clip | Original, 720p | AV1 + AAC, MKV | 44.489 s | 1,333 / 1,916 |
| Same YouTube clip | Audio only | AAC, M4A | 44.489433 s | — / 1,916 |
| [Dailymotion: Office Christmas Party review](https://www.dailymotion.com/video/x5kesuj) | Original, 288p HLS | H.264 + AAC, MKV | 186.868 s | 5,597 / 4,019 |
| Same Dailymotion page | Compatible MP4, 288p HLS | H.264 + AAC, MP4 | 186.868111 s | 5,597 / 4,019 |
| [SoundCloud: The Following](https://soundcloud.com/the80m/the-following) | Audio-only HLS | AAC, M4A | 397.175896 s | — / 17,105 |

The checked case configuration, final probes, SHA-256 values and decode outcomes
are in [the evidence folder](evidence/2026-10-29-multisite/), including
[live-results.json](evidence/2026-10-29-multisite/live-results.json) and
[live-cases.json](evidence/2026-10-29-multisite/live-cases.json).

### Vimeo limits observed

[Vimeo 76979871](https://vimeo.com/76979871) resolved through its public player page,
but its selected HLS media playlist carried SAMPLE-AES/FairPlay. The extractor's
format metadata reported no DRM; the engine correctly rejected the actual playlist
with “This stream uses an unsupported or incomplete encryption method.” No completed
media file was published. No protection bypass was attempted.

A separate upstream public sample, [Vimeo 33951933](https://vimeo.com/33951933),
returned HTTP 401 during extraction. These are failed/access-limited site checks,
not successful Vimeo download coverage. Sample URLs came from the official
[yt-dlp Vimeo extractor tests](https://raw.githubusercontent.com/yt-dlp/yt-dlp/master/yt_dlp/extractor/vimeo.py).

## Native app checks

Built and launched fresh arm64, ad-hoc signed Debug builds; the final build includes
all code changes and the rebuilt vendor helper. Used native accessibility controls,
not app-state injection. Main library data and browser cookies were preserved.

- **Pasted YouTube link, final build:** selected default compatible MP4 at 720p;
  completed as a de-collided `(3).mp4`. Full decode passed, H.264/AAC, 1,333/1,916
  packets, 44.489433 s. SHA-256
  `57ae0d54389239755143e15bf9f1a8525bb07f063b99f5b88cf94fde52e62633`, matching the
  previously verified complete file. See [completion](evidence/2026-10-29-multisite/youtube-pasted-final-completed.png).
- **Built-in browser, Dailymotion:** opened the page, used its one primary media
  shelf item, selected 480p MP4 and completed with the signed sandboxed helper.
  Full decode passed, H.264/AAC, 186.799844 s, 5,597 video / 8,041 audio packets.
  See [picker](evidence/2026-10-29-multisite/dailymotion-mp4-picker-dark.png),
  [completion](evidence/2026-10-29-multisite/dailymotion-browser-mp4-completed-dark.png)
  and [probe](evidence/2026-10-29-multisite/dailymotion-browser-mp4.probe.json).
  YouTube browser intake was also verified in the [preceding MP4 audit](2026-10-29-mp4-output.md).
- **Pasted SoundCloud:** audio-only sheet, usable Download action, complete M4A
  placed under Audio; full decode passed with its 397.175896 s timeline.
  See [light picker](evidence/2026-10-29-multisite/soundcloud-audio-picker-light.png)
  and [completed audio](evidence/2026-10-29-multisite/soundcloud-audio-completed.png).
- **Dark/compact sheets:** 440-point-wide video and audio modes, readable selection
  and buttons, Vimeo's duplicate English tracks distinguished as `(1)` and `(2)`;
  sheet cancellation worked. See [audio groups](evidence/2026-10-29-multisite/vimeo-audio-groups-dark.png).
- **Protected error:** Vimeo failed visibly with no completed output. See
  [failed-state evidence](evidence/2026-10-29-multisite/vimeo-protected.png).
- Removed only this audit's four completed GUI test records/files (SoundCloud,
  Dailymotion original, Dailymotion MP4, final YouTube) and the failed Vimeo record.
  The original four library entries remain. Four test completions/associated bytes
  remain in lifetime statistics; no statistics or browsing data were reset. Normal
  appearance and the All view were restored; the verification browser was closed.

## Automated verification

- Full core suite passed with `FFMPEG_PATH` pointing to the vendor binary. Swift
  Testing reports 14 + 341 + 295 tests across 90 suites; the opt-in live test is
  skipped in a normal run and separately passed all six live cases above.
- Added synthetic fragmented AAC, Opus, MPEG-TS, mislabeled TS, compatible-HLS,
  audio-identity/persistence and audio-group regressions. Explicit output failure
  retains staging and cannot publish a raw video-container result for an audio request.
- Existing HLS/DASH, AES-128, unsupported-encryption, range validation, interrupted
  transfer/resume, relaunch, cancellation, no-overwrite and paired-mux failure tests
  remain green. Relaunch coverage is logical recovery, not physical power-loss proof.
- Browser playback regression passed: closing a window unloads its playing iframe
  and does not restart playback. This uses an ephemeral local WebKit fixture.
- `swiftlint --strict`: 178 files, zero violations.
- Localization validation: 501 strings × 10 languages, all translated and consistent.
- Xcode arm64 Debug build succeeded. [Condensed check evidence](evidence/2026-10-29-multisite/checks.txt).

Run the live suite using [the smoke-test guide](../../apps/macos/scripts/tests/README.md).
It is opt-in, uses an in-memory store, and retains failure details only in the caller's
private temporary directory. Committed evidence excludes expiring CDN URLs/cookies.

## Helper configuration and limits

FFmpeg remains 9.0.2, rebuilt from the same verified source archive with only native
AAC decoding enabled for probing. Vendor binary SHA-256:
`1e1ab256dfddec185ab2d9db21eed5517a52882b7a000c6467159316289136b8`.
Its protocol inventory remains exactly `file`, `pipe`, `fd`; its decoder inventory
contains only AAC; its encoder inventory is empty. The build verifies arm64,
ad-hoc signing and system-only dynamic linkage. The app re-signs the helper with
sandbox inheritance. No third-party library was added.

Dependency versions and the accepted frozen yt-dlp runtime exceptions remain as
recorded in the [dependency refresh audit](2026-10-29-youtube.md). This task changes
FFmpeg's configuration, not its version. HLS with unknown codec metadata and generic
DASH manifests do not automatically gain the compatible-MP4 offer. Original quality
may still use MKV; incompatible source codecs are not transcoded. Protected or
login-restricted media can remain unavailable. Debug testing does not establish
Developer ID/notarization or Release App Group/Share Extension behavior.
