# CloakDrop Architecture

CloakDrop is split into a **thin SwiftUI app shell** and a **headless, UI-agnostic core**
packaged as a local Swift package. The core builds and tests without launching a GUI, and the
engine never imports SwiftUI. This document describes the source checked on **6 September 2026**;
published betas can lag behind it. See the [implementation audit](../../docs/audits/2026-09-06-overview.md)
for the latest recorded verification and its limits.

```
┌──────────────────────────── App target (CloakDrop) ────────────────────────────┐
│  SwiftUI Views ── AppModel (@MainActor @Observable) ── Ambient (Dock/Menu/Notif) │
└───────────────────────────────────┬─────────────────────────────────────────────┘
                                     │ async calls / AsyncStream<EngineEvent>
┌────────────────────────────────────▼─────────────────────────────── DownloaderCore ┐
│  DownloadEngine        DownloadPersistence            DownloadModels                 │
│  ── DownloadManager    ── DownloadStore (protocol)    ── Download, Segment, Queue,   │
│     (actor)            ── GRDBDownloadStore              Status, Settings, …          │
│  ── DownloadTask                                        (all Sendable value types)   │
│     (actor, 1/​download)                                                             │
│  ── HTTPClient (protocol) → SchemeRoutingHTTPClient → URLSession / FTPClient / Mock  │
│  ── SegmentPlanner · BandwidthLimiter · ChecksumVerifier · NetworkMonitor · Keychain │
└──────────────────────────────────────────────────────────────────────────────────┘
```

## Modules

### `DownloadModels`
Pure, `Sendable` value types with **no dependencies**: `Download`, `DownloadSegment`,
`DownloadStatus`, `DownloadQueue`, `EngineSettings`, `FileCategory`, `ChecksumExpectation`,
`SmartFilter`, `DownloadRequest` (including the `mirrors` list for multi-source downloads),
`DownloadProgress`, errors. Also the adaptive-streaming model
(`MediaStream` → `MediaVariant` → `MediaSegment`, plus tracks/init/encryption) with the I/O-free
`HLSParser` and `DASHParser`; the **Metalink** model (`MetalinkFile`) with its I/O-free `MetalinkParser`
and the `DownloadRequest(metalink:)` bridge (strongest mirror → primary URL, the rest → failover
mirrors, whole-file checksum carried through); the lifetime `DownloadStats` counters (today / this-month /
all-time bytes); the checksum-sibling logic (`ChecksumDiscovery`); the capture payload
(`CapturedDownload`) shared by every intake path; and the built-in browser's media sniffer
(`MediaSniffer` + its dedupe cascade, `PageMediaState`, and the injected collector script) plus
`BrowserCookies`. The Swift classifier and value types are DOM-free and tested against a captured
fixture corpus; the bundled JavaScript collector runs in WebKit and has JavaScriptCore execution tests.
Because they're plain values, they cross actor boundaries freely and are trivial to test. The
on-device *intake intelligence* lives here too, all pure and I/O-free: `LinkPreview` (the pre-flight
  result), `DuplicateDetector`/`DuplicateCandidate` (duplicate warnings by URL / same-origin ETag /
completed name+size; no content-hash library yet), `SignatureAssessment` + `TrustLevel` (the unified trust
signal from checksum + code signature), the smart-rule model (`SmartRule`, `SmartRuleCondition`,
`SmartRuleAction`, `RuleInput`) with its evaluator `SmartRuleEngine`, the link-grabber parser
(`PageLinkExtractor` — resolve/dedupe/filter a page's href/src links; `URLBatch` — pattern expansion),
`VideoPageDetector` (recognizes, by curated host, when a pasted URL is a video page to hand the
extractor rather than download as a file),
the time-of-day `BandwidthSchedule` (resolves the effective cap by clock, wraps past midnight), and
the `ProvenanceReceipt` (an exportable local evidence record, with control-char-sanitized text
rendering). A receipt can remain unverified: its presence does not establish publisher identity,
notarization, or a Gatekeeper verdict.

### `DownloadPersistence`
A `DownloadStore` **protocol** (so the engine can be tested against an in-memory fake) and a
`GRDBDownloadStore` implementation. Each `Download` is persisted as a JSON payload alongside
indexed scalar columns (status/queue/category/order) — a stable schema that stays queryable as
the model evolves. Migrations via GRDB's `DatabaseMigrator`. A separate per-day byte-bucket table
(migration v3) records the bytes of each *completed* download keyed by the day it finished, so
`loadStats(asOf:)` can derive today / this-month / all-time totals for Settings ▸ Stats and
`resetStats()` clears them.

### `DownloadEngine`
The concurrency core. Manager and transfer state are actor-isolated; networking adapters use
serial delegate queues and narrowly scoped locks to bridge callbacks into asynchronous streams.

- **`DownloadManager`** (actor) — the single entry point. Owns the catalog of downloads and
  queues, enforces per-queue concurrency, persists state, and drives one `DownloadTask` per
  active transfer. Publishes an `AsyncStream<EngineEvent>` the UI renders. Subscribes to
  `NetworkMonitor` to auto-pause on connectivity loss and auto-resume on return.
- **`DownloadTask`** (actor, one per download) — probes the server, chooses an automatic or persisted
  per-download connection count, plans segments, transfers them concurrently, throttles, streams
  progress, verifies ordinary-file staging data, then finalizes. The concurrent
  segment workers are **non-isolated free functions** (`runSegment`) that report byte deltas
  back through actor methods, so the authoritative state mutates serially. When a
  download carries Metalink `mirrors`, each worker is seeded at a different source (so segments
  **spread** across mirrors for parallel throughput) and **advances to the next mirror on retryable
  failures**. Response validation rejects a source that ignores `Range`, returns a different
  `Content-Range`, advertises a different total, or changes an available same-origin ETag before a
  byte is written. Body validation also rejects short or oversized ranged responses, including an
  extra chunk after the expected range is filled. An invalid completed prefix cannot escape through
  mirror failover; it forces a coherent whole-file restart. A permanent HTTP error fails promptly;
  transient failures sweep every configured source at least once. Equal-length mirror content is
  not proven identical by these checks; a supplied whole-file checksum is the corruption backstop.
- **`HTTPClient`** (protocol) — the single networking boundary (`probe` + `stream`). In production
  a `SchemeRoutingHTTPClient` dispatches by URL scheme: `http(s)` → `URLSessionHTTPClient`
  (delegate-driven, chunked `Data`, cancellable); `ftp`/`ftps` → the native **`FTPClient`**. HTTP
  requests use identity encoding so probe/range/fallback requests address the same representation.
  Body streams have bounded buffers with producer backpressure, and cancellation also tears down a
  request that is still waiting for response headers, including cancellation racing with handler
  registration. Stream handlers are keyed by `ObjectIdentifier(URLSessionTask)`, so replacing the
  sessions after a proxy change cannot confuse reused numeric task IDs. Tests and previews use
  `MockHTTPClient` (in-memory, supports Range, injectable drops and malformed-range responses).
- **Native FTP/FTPS (`FTPClient`)** — an FTP client over **Network.framework** (`NWConnection`), no
  bundled library. Speaks EPSV/PASV passive data connections, `SIZE`, and `REST` for byte-range
  resume, with implicit TLS for `ftps`. The probe tests `REST` support rather than assuming it; a
  server without it remains a valid single-stream source. A ranged request reports `statusCode: 206`
  so the segment engine treats an offset transfer like an HTTP partial; FTP's client enforces the
  requested end offset locally because `REST` only supplies a starting offset. Control operations
  and active data reads have a 30-second default deadline, bounded reply/body buffers and cooperative
  cancellation. Consumer backpressure suspends the read deadline rather than timing out a deliberately
  throttled transfer. Ports, passive replies and nonnegative sizes are validated; command arguments
  reject CR, LF and NUL. PASV uses the control host with the validated passive port for NAT compatibility
  and to avoid peer-directed connections to unrelated addresses. FTP/FTPS bypass the app's HTTP proxy
  configuration. Explicit `AUTH TLS` is unsupported, and completion replies are drained best effort.
- **Saved credentials (`CredentialStoring` → `KeychainCredentialStore`)** — remembered per-site
  HTTP/FTP logins and the manual-proxy password live in the **Keychain** (`kSecClassGenericPassword`,
  keyed on an opaque identifier, `…AfterFirstUnlockThisDeviceOnly`). The proxy password is blanked
  from the settings payload and rehydrated into memory at launch. Credentials attached to one
  download are also part of that local download record so it can resume; deleting the record removes
  that copy.
- **HTTP authentication boundaries** — ordinary mirror probes and body requests retain credentials,
  `Authorization`, `Proxy-Authorization` and flattened `Cookie` headers only for the original origin
  (scheme, case-insensitive host and effective port). Both HTTP sessions strip these sensitive headers
  on cross-origin redirects. Challenge credentials use the same origin boundary, with a separate
  proxy-host/port scope; TLS trust uses the system's default handling. Media still has one shared
  request-header set per plan, so these ordinary-transfer guarantees must not be read as a complete
  per-rendition media-authentication policy.
- **Archive extraction (`ZipArchive`)** — optional native ZIP auto-extraction via
  **Compression.framework** (STORE + raw DEFLATE), memory-mapped, guarded against Zip-Slip path
  traversal and decompression bombs (compression-ratio + hard-size caps). It never runs after a
  known checksum mismatch; when checksum verification is enabled and a checksum exists, verification
  completes first. Extracted files receive quarantine when that setting is enabled.
- **Pure helpers** — `SegmentPlanner` (segmentation math), `BandwidthLimiter` (a **GCRA
  virtual-clock** rate limiter — a shared limiter caps *aggregate* throughput correctly across all
  concurrent segment workers, unlike a naive per-connection token bucket), `BackoffPolicy` (retry
  timing), `ChecksumVerifier` (CryptoKit), `SpeedSampler` (rate estimate). Planning, timing and
  sampling policy have focused unit tests; checksum tests also exercise file reads.
- **Speed test (`SpeedTester`)** — an actor orchestrating the built-in, strictly user-initiated
  connection test behind its own transport seam (`SpeedTestTransport` → `URLSessionSpeedTestTransport`
  in prod, a scripted mock in tests): idle-latency probes, then parallel download/upload workers with
  warm-up exclusion (`SpeedTestMath`, pure and unit-tested) while sampling loaded latency for a
  bufferbloat signal. Providers: Cloudflare's speed endpoints (default) or Ookla's public server
  directory—one of the app's disclosed, user-started network surfaces.
- **Intake seams** — `LinkInspector` turns one `HTTPClient.probe` into a `LinkPreview` (final URL
  after redirects, size, proven range support, MIME, ETag, automatic connection estimate) for the add
  sheet's live pre-flight; `CodeSignatureInspecting` (protocol → `SecCodeSignatureInspector`, Security framework,
  in-process, no network) assesses a finished `.app`/`.dmg`'s code signature in `DownloadTask.finalize`.
  Smart-rule routing is applied in `DownloadManager.add` (folder / queue / speed cap / auto-start).
  After verify, and only when enabled, the ordinary-file path assembles the **`ProvenanceReceipt`**
  from signals already in the transfer path—requested source, configured mirrors, encrypted-
  transport flag, whole-file SHA-256 (reused from the verify pass when available), and checksum +
  signature verdicts. Its `TrustLevel` is derived specifically from checksum and signature status;
  the other fields are recorded evidence, not trust inputs.
- **Media resolution** — `MediaResolver` fetches and parses a manifest URL into a ready `MediaPlan`.
  Each redirected manifest is parsed relative to its final response URL, including variant, audio,
  subtitle, initialization, key and segment URLs. Fetches are cancellation-aware and bounded to
  16 MiB by default. HLS validates byte ranges and sequence arithmetic; HLS/DASH bound numeric
  dimensions and durations, and DASH guards timeline/template arithmetic and expansion sizes.
  These are supported finite manifest plans, not a live-playlist recording loop.
- **Audio selection** — `MediaStream.audioTrack(for:)` selects a rendition's separate audio.
  Manifest-derived DASH keeps its audio set even when reached through a page extractor; direct
  progressive extractor tiers keep their existing sound. Optional `MediaVariant.videoTrackPresent`
  preserves explicit extractor evidence without breaking older Codable records. Failure to resolve
  required separate audio now fails preparation. Audio-only plans choose from
  `standaloneAudioTracks`/`defaultStandaloneAudioTrack`, excluding URI-less in-band HLS renditions;
  ordinary video selection can still use those in-band defaults. Subtitle resolution remains best effort.
- **Media transfer and assembly** — `DownloadTask` grabs video and resolved audio segments through a
  bounded rolling work window, decrypting supported HLS AES-128 (`AES128`), then attempts passthrough
  mux/remux. Unsupported encryption is rejected before transfer.
  A *whole-file* segment (a progressive / paired video+audio grab, as YouTube serves its `adaptiveFormats`) is
  fetched in bounded **~10 MB ranged chunks** on a range-capable server—a mitigation for the
  per-connection throttling observed on some CDNs (including googlevideo's `n`-throttle), without
  promising a particular origin or network speed. HLS/DASH's many small segments download as-is. Selected
  subtitle tracks are converted (`SubtitleConverter`, WebVTT → SRT) and written as sidecar `.srt`
  files next to the finished video. The `Remuxer`
  protocol has two backends behind a `CompositeRemuxer` (tries each in order): `AVFoundationRemuxer`
  first — fast, in-process, no dependency, H.264/HEVC + AAC → `.mp4`/`.m4a` — falling back to a
  bundled `FFmpegMuxer` (stream-copy via a `Process`) for the codecs AVFoundation can't carry
  (VP9/AV1/Opus → `.mkv`). No re-encoding occurs. Unlike required-audio resolution, assembly remains
  best effort: if every mux backend fails, finalization tries video-only remux and can publish the
  video assembly without its separate audio. Subtitle fetch/conversion failure also does not fail a
  completed grab. `MediaThumbnailer` renders a poster frame. These operations sit behind protocols /
  injected seams, so the transfer path stays testable against `MockHTTPClient`.
- **Page extraction (yt-dlp)** — `MediaExtractor` (protocol) resolves a *page* URL (a YouTube
  watch page, or another site supported by the bundled yt-dlp version) into its available video/audio
  formats (`ExtractedMedia` / `ExtractedFormat`). It is a **resolver / decipher oracle, not a
  downloader**: the production `YtDlpExtractor` spawns the bundled, code-signed `yt-dlp` binary
  with `-J` (dump-single-json), explicit `--simulate`, `--ignore-config`, `--no-plugin-dirs`,
  `--no-cache-dir` and `--no-playlist`; the page follows an argument terminator. Only HTTP(S) page
  URLs are accepted. It may contact the submitted page and related service endpoints to
  resolve metadata and media URLs, then prints JSON to stdout; it never touches the destination or
  transfers the selected media payload. CloakDrop's own segmented engine does those payload bytes,
  so pause/resume, persistence, and the sandbox story stay ours. Subprocess spawning is behind
  `ProcessRunning` (`SystemProcessRunner` in prod, captured to temp files with a hard timeout so a
  multi-MB dump can't deadlock a pipe; a mock in tests), and `ExtractedMedia+Mapping` folds the
  result into the existing `MediaStream`/`MediaPlan` quality picker. Mapping retains parent HLS/DASH
  manifests and merges top-level/format headers case-insensitively, with selected-format values
  taking precedence. Direct formats exclude explicit DRM, non-HTTP(S) URLs and playlist resources;
  audio-only sources and codec-omitted audio containers are supported. Audio groups preserve language
  identity, and an unpaired silent direct tier cannot displace an available complete tier.
  `locate(in:)` detects an executable file at launch to enable extraction — mirroring
  `FFmpegMuxer.locate`; runtime and site failures are still surfaced when used. The bundled yt-dlp
  is refreshed through normal app updates. Its subprocess
  currently has no explicit seam for the app's manual proxy setting; manifest and payload requests
  use the configured engine HTTP client.

## Concurrency model

- **Actor-owned download state.** Mutable coordination lives in the `DownloadManager` actor;
  per-download mutable state lives in its `DownloadTask` actor. Callback adapters synchronize their
  own transport state with locks or serial queues.
- **Connection selection is explicit and bounded.** Automatic mode keeps the configured default for
  ordinary files and scales large files toward the configured maximum while respecting minimum
  segment size. A per-download manual choice overrides the automatic target but is still clamped to
  the resource and global maximum. The choice persists across scheduling and relaunch.
- **Parallel segments** run through a rolling `withThrowingTaskGroup` window inside the task. It
  launches no more than the current connection budget—even when a resumed segment table contains
  old work-stealing tails—and feeds pending segments into slots as they finish. Each child opens its
  **own** `FileHandle` into the shared sparse part file at a disjoint offset. Actor-owned write
  reservations keep a worker's in-flight write out of a tail being reassigned.
- **Dynamic re-splitting (work-stealing).** When a worker finishes its region while others are
  still going, it steals the largest remaining tail from a straggler — splitting that segment and
  taking over the back half when enough useful work remains, reducing the slow-tail period without
  exceeding the connection budget.
- **Pause/cancel** is cooperative: the manager sets a stop reason then cancels the task's
  enclosing `Task`; structured cancellation propagates to the segment children, which unwind and
  let the task persist a paused/canceled state. Manager-to-task persistence handoff is ordered, and
  terminal saves drain pending work so stale checkpoints cannot resurrect removed/completed records.
- **UI isolation:** `AppModel` is `@MainActor @Observable`. It consumes the engine's event stream
  (the consuming `Task` inherits the main actor) and mirrors events into observable state. Live
  progress (≈10/sec) flows through a separate `progress` dictionary so it never thrashes the
  status-level `downloads` array or the database. Media progress uses live bytes and, for timed/ranged
  segments, completed/total segment counts; whole-file media progress uses bytes. Paused rows do not
  keep displaying the last running speed, and unknown totals/ETAs are omitted rather than rendered
  as misleading fractions.

## Data flow for a download

1. UI builds a `DownloadRequest` → `DownloadManager.add`.
2. Manager creates a `Download`, persists it, emits `.downloadAdded`, and schedules it if a queue
   slot is free.
3. `DownloadTask.run`: probe (best-first across mirrors when a Metalink supplied them) → choose the
   connection budget → plan segments (or a single stream) → size the `.cdpart` file exactly → transfer
   through the bounded rolling scheduler with retry/resume + mirror failover + work-stealing +
   throttle → emit throttled `.progress` events and periodically persist. If a server's ranged
   response is invalid, discard the coherent staging set and retry once as a whole stream. A whole
   response cannot be unsolicited HTTP 206; it must satisfy any advertised length without truncating
   an oversized body into a successful result.
4. On ordinary-file completion: when enabled, resolve and verify any checksum **against `.cdpart`** →
   move staging to an unoccupied destination without replacing an existing file/directory → optionally
   (default on) stamp Gatekeeper quarantine → optionally extract ZIP → assess the local code signature → optionally build the
   Provenance Receipt → mark completed and emit the update. Media plans assemble/remux their persisted
   `.cdparts` through their separate finalize path. The manager fills the freed queue slot; when all
   work has drained it emits `.allDownloadsCompleted`, and `AppModel` applies the configured all-done
   action once for that work cycle.

## Persistence & resume

Ordinary-file bytes are written into a single sparse `*.cdpart` file; each segment owns a contiguous
byte region. Known-size staging is resized exactly in both directions. An unknown-size retry starts
from a truncated empty file, and successful whole-file transfer trims staging to the actual accepted
length, preventing stale trailing bytes from an older attempt. Oversized-body failure invalidates
accepted progress so a later retry cannot publish the prefix.

Per-segment `downloadedBytes` is persisted, so compatible ranged resume starts at
`segment.start + downloadedBytes`. Integration tests pause mid-flight, discard the manager and resume
a new manager against the same database and part file; a running-app relaunch test also completed with
an independent SHA-256 match. Missing staging, changed size/available validators and incompatible
range behavior trigger recovery rather than blind reuse. Equal-length changes remain undetectable
without a usable validator or trusted checksum; Last-Modified is not a persisted fallback today.

These tests establish process/manager replacement behavior, **not physical power-loss durability**.
Mid-transfer checkpoints are best effort and do not establish a transactional barrier between file
`fsync` and the database. A clean EOF with neither a known length nor a checksum cannot prove that an
origin sent everything it intended. Media persists a resolved plan and completed parts in `.cdparts`;
expired signed URLs are not automatically re-resolved on resume.

Suggested names are reduced to safe basenames and reserved case-insensitively against cataloged
downloads and existing destination entries. Distinct catalog names imply distinct staging paths for
concurrent adds; reused staging is reset/resized as appropriate. Finalization refuses replacement if
another process wins the remaining race. Ordinary checksums are verified before publication, and a
failed publication remains retryable.

## Sandbox

The app is fully sandboxed. The default Downloads folder is covered by entitlement; user-chosen
folders are persisted as **security-scoped bookmarks** and activated (`SecurityScope`) for the
duration of each transfer.

GRDB is the only third-party Swift package (7.11.1 in the tracked core `Package.resolved`). The core
package targets macOS 15+, while the SwiftUI app requires macOS 26 and the optional vendor helpers
are built/prepared for arm64. `project.yml` is the source of truth for generated Xcode projects.
The opt-in ffmpeg and yt-dlp fetch scripts pin source/archive versions and SHA-256 values, prepare and
verify helpers before replacement, and build phases verify signatures and remove stale absent helpers.
ffmpeg is restricted to local `fd`, `file` and `pipe` protocols; yt-dlp's inherited sandbox permits the
submitted-page metadata work described above. Local ad-hoc signatures do not establish Developer ID
distribution or notarization.

The [dependency audit](../../docs/audits/2026-09-06-dependencies.md) records the checked versions,
signatures and runtime inventory. In particular, the official yt-dlp bundle still carries older
runtime components, including an outstanding OpenSSL security patch; no custom runtime has been
substituted. “Latest helper release” must not be interpreted as “every bundled library is current.”

## Capture

The primary capture surface is the **built-in browser** (`App/Features/Browser/`): a WKWebView the
user opens from the app, navigates anywhere, and grabs media from. A collector script injected into
every frame (document-start, page world) reports raw sightings — resource URLs, response headers,
`<video>`/`<audio>` elements (including players inside open *and closed* shadow roots, via a
wrapped `attachShadow`), MediaSource signals, SPA navigations — to the app, where the pure
`MediaSniffer` (pure and DOM-free, run against a captured fixture test
corpus) classifies, dedupes, and ranks them into the shelf. The classifier filters recognized
ad-network hosts, analytics beacons, adaptive-stream chunks (segment extensions, byte-windowed
`bytestart=`/`range=` fetches), and UI sound effects. This policy is heuristic, not a promise to identify
every site's unwanted resource. DRM is flagged only on
real engagement — `setMediaKeys` with keys, or an `encrypted` media event — never on the capability
probes players run against clear content. A sniffed stream is shown and saved under the **page
title** (its URL only names a manifest); the engine appends the container extension once the plan
is known. Grabs and IDM-style download takeovers
become `CapturedDownload`s and route through the same media/add funnels as everything else; every
byte is still fetched by the engine with the applicable captured request context. The collector's
bounded dedupe cache evicts older entries, so crossing 800 distinct resource URLs no longer disables
later discovery; SPA navigation resets page state. The shelf intentionally selects one primary media
item, and an HLS candidate can outrank a direct MP4 from the same page.

Browser extraction can use a private Netscape cookie-jar copy with domain/path scope. Flattened page
cookies are restricted from crossing into an unrelated media host. The final media plan still shares
one header set across video, audio, keys and subtitles; sites needing different credentials per
resource/CDN can fail. Supported page detection and observed browser traffic broaden capture, but
neither guarantees every site, protected rendition, login state or region. HLS live URLs currently
produce a finite snapshot: there is no sliding-window refresh or complete live-recording lifecycle.

An optional **ad/tracker blocker** (off by default; Settings ▸ Browser) rides on the same browser.
The ruleset is pure data — `AdBlockList` (in `DownloadModels`, unit-tested) emits a WebKit
**content-rule list** (the Safari content-blocker JSON format): a block rule per ad/tracker host
(seeded from the sniffer's `adHostSuffixes`, broadened with trackers and pop/push-ad networks), a
few third-party-only ad path rules, and one cosmetic `display:none` rule for ad containers. The app
layer (`BrowserStore`) compiles it once via `WKContentRuleListStore` — WebKit enforces it in its
networking process, so ad requests are dropped *before* egress — caches the compiled list, and evicts
stale versions by identifier hash. Popups aimed at a blocked host are rejected in the UI delegate
(the network rules can't see a brand-new top-level load). Downloads never pass through the list —
only in-browser page loads do.

The blocker's coverage is selectable (Settings ▸ Browser): the built-in curated ruleset, or an
**open-source domain blocklist** — OISD Small, StevenBlack Hosts, or Peter Lowe's — layered on top
of it as a second compiled rule list. `BlocklistParser` (in `DownloadModels`, unit-tested) folds all
the common list formats (plain domains, hosts files, wildcard and bare-domain ABP lines) into
validated domains whose charset is *inert* in a `url-filter` regex — a hostile list can drop entries
but never inject rule syntax — then prunes subdomains already covered by a listed parent and caps
under WebKit's 150k-rules-per-list limit. `BrowserStore+Blocklists` fetches on user action only
(picking a list or Update Now — never on a timer or at launch), over the same proxy as browsing,
validates a per-source minimum-entry floor before replacing the previous copy, persists the
canonical domains + metadata in Application Support, and compiles under a content-hashed identifier.
Every step re-checks the active source after each await, and any failure leaves the previous list —
or the curated baseline — in effect: fail-open, never broken.

The other intake paths — the `cloakdrop://` URL scheme, the Share Extension, and the in-process
Services item — funnel into the same validated `CapturedDownload` value. The Share Extension hands
off **without any cross-process network path**: it writes the capture as JSON into a shared **App
Group** container (`CaptureInbox`) and posts a payload-free Darwin notification; the app drains the
inbox on that signal and on launch. App Groups require a team, so the shared-inbox path lives only
in the **Release** entitlements; Debug builds fall back to the `cloakdrop://` deep link.

## Verification and remaining work

The 6 September 2026 coordinated core run passed **593 tests in 83 suites**: 14 persistence,
314 model and 265 engine tests. It covers ordinary/media relaunch, transfer validation, HTTP/FTP
loopback behavior, cancellation races, mirror/authentication boundaries, malformed manifests and
executed collector JavaScript. The app was built/analyzed and visually exercised in light and dark
appearance; the [overview](../../docs/audits/2026-09-06-overview.md) records the workflows and screenshots.
Counts are dated evidence, not a substitute for rerunning checks after source changes.

See the [engine audit](../../docs/audits/2026-09-06-engine.md) and
[media audit](../../docs/audits/2026-09-06-video.md) for unresolved durability, identity and compatibility
boundaries. Further work includes disk/persistence fault injection, long-duration large-file and
removable-volume soak tests, wider proxy/FTPS coverage, per-resource media authentication, explicit
extractor proxy routing, expired-URL refresh and live recording. No throughput benchmark gain or
universal-site compatibility is claimed by the current tests.
