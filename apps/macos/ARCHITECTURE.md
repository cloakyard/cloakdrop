# CloakDrop Architecture

CloakDrop is split into a **thin SwiftUI app shell** and a **headless, UI-agnostic core**
packaged as a local Swift package. This is the modern macOS layout: the core builds and tests
in seconds without launching a GUI, and the engine never imports SwiftUI.

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
`BrowserCookies` — all pure, DOM-free, and unit-tested against a captured fixture corpus.
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
the `ProvenanceReceipt` (the exportable verified-download record, with control-char-sanitized text
rendering).

### `DownloadPersistence`
A `DownloadStore` **protocol** (so the engine can be tested against an in-memory fake) and a
`GRDBDownloadStore` implementation. Each `Download` is persisted as a JSON payload alongside
indexed scalar columns (status/queue/category/order) — a stable schema that stays queryable as
the model evolves. Migrations via GRDB's `DatabaseMigrator`. A separate per-day byte-bucket table
(migration v3) records the bytes of each *completed* download keyed by the day it finished, so
`loadStats(asOf:)` can derive today / this-month / all-time totals for Settings ▸ Stats and
`resetStats()` clears them.

### `DownloadEngine`
The concurrency core. Everything mutable is actor-isolated.

- **`DownloadManager`** (actor) — the single entry point. Owns the catalog of downloads and
  queues, enforces per-queue concurrency, persists state, and drives one `DownloadTask` per
  active transfer. Publishes an `AsyncStream<EngineEvent>` the UI renders. Subscribes to
  `NetworkMonitor` to auto-pause on connectivity loss and auto-resume on return.
- **`DownloadTask`** (actor, one per download) — probes the server, chooses an automatic or persisted
  per-download connection count, plans segments, transfers them concurrently, throttles, streams
  progress, verifies ordinary-file staging data, then finalizes. The concurrent
  segment workers are **non-isolated free functions** (`runSegment`) that report byte deltas
  back through actor methods, so the authoritative state mutates serially and race-free. When a
  download carries Metalink `mirrors`, each worker is seeded at a different source (so segments
  **spread** across mirrors for parallel throughput) and **advances to the next mirror on retryable
  failures**. Response validation rejects a source that ignores `Range`, returns a different
  `Content-Range`, advertises a different total, or changes a same-origin ETag before a byte is
  written. A permanent HTTP error fails promptly; transient failures sweep every configured source
  at least once. A supplied whole-file checksum is the backstop against otherwise-undetectable byte
  corruption.
- **`HTTPClient`** (protocol) — the single networking boundary (`probe` + `stream`). In production
  a `SchemeRoutingHTTPClient` dispatches by URL scheme: `http(s)` → `URLSessionHTTPClient`
  (delegate-driven, chunked `Data`, cancellable); `ftp`/`ftps` → the native **`FTPClient`**. HTTP
  requests use identity encoding so probe/range/fallback requests address the same representation.
  Body streams have bounded buffers with producer backpressure, and cancellation also tears down a
  request that is still waiting for response headers. Tests and previews use `MockHTTPClient`
  (in-memory, supports Range, injectable drops and malformed-range responses).
- **Native FTP/FTPS (`FTPClient`)** — an FTP client over **Network.framework** (`NWConnection`), no
  bundled library. Speaks EPSV/PASV passive data connections, `SIZE`, and `REST` for byte-range
  resume, with implicit TLS for `ftps`. The probe tests `REST` support rather than assuming it; a
  server without it remains a valid single-stream source. A ranged request reports `statusCode: 206`
  so the segment engine treats an offset transfer exactly like an HTTP partial. Control + data
  connections carry idle timeouts, bounded reply/body buffers, and cooperative cancellation so a
  dead or slow server does not cause unbounded memory growth or wedge a transfer indefinitely.
- **Saved credentials (`CredentialStoring` → `KeychainCredentialStore`)** — remembered per-site
  HTTP/FTP logins and the manual-proxy password live in the **Keychain** (`kSecClassGenericPassword`,
  keyed on an opaque identifier, `…AfterFirstUnlockThisDeviceOnly`). The proxy password is blanked
  from the settings payload and rehydrated into memory at launch. Credentials attached to one
  download are also part of that local download record so it can resume; deleting the record removes
  that copy.
- **Archive extraction (`ZipArchive`)** — optional native ZIP auto-extraction via
  **Compression.framework** (STORE + raw DEFLATE), memory-mapped, guarded against Zip-Slip path
  traversal and decompression bombs (compression-ratio + hard-size caps). It never runs after a
  known checksum mismatch; when checksum verification is enabled and a checksum exists, verification
  completes first. Extracted files receive quarantine when that setting is enabled.
- **Pure helpers** — `SegmentPlanner` (segmentation math), `BandwidthLimiter` (a **GCRA
  virtual-clock** rate limiter — a shared limiter caps *aggregate* throughput correctly across all
  concurrent segment workers, unlike a naive per-connection token bucket), `BackoffPolicy` (retry
  timing), `ChecksumVerifier` (CryptoKit), `SpeedSampler` (rate estimate). Each is isolated from
  I/O so it is exhaustively unit-tested.
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
- **Media** — `MediaResolver` fetches + parses a manifest URL into a ready `MediaPlan` and attempts to
  pair an adaptive video rendition with its separate audio track; failed audio resolution degrades
  to a video-only grab rather than failing the transfer. `DownloadTask` grabs the video and any
  resolved audio segments through a bounded rolling work window, decrypting AES-128 (`AES128`), then
  muxes and passthrough-remuxes the result into a clean container.
  A *whole-file* segment (a progressive / paired video+audio grab, as YouTube serves its `adaptiveFormats`) is
  fetched in bounded **~10 MB ranged chunks** on a range-capable server—a mitigation for the
  per-connection throttling observed on some CDNs (including googlevideo's `n`-throttle), without
  promising a particular origin or network speed. HLS/DASH's many small segments download as-is. Selected
  subtitle tracks are converted (`SubtitleConverter`, WebVTT → SRT) and written as sidecar `.srt`
  files next to the finished video. The `Remuxer`
  protocol has two backends behind a `CompositeRemuxer` (tries each in order): `AVFoundationRemuxer`
  first — fast, in-process, no dependency, H.264/HEVC + AAC → `.mp4`/`.m4a` — falling back to a
  bundled `FFmpegMuxer` (stream-copy via a `Process`) for the codecs AVFoundation can't carry
  (VP9/AV1/Opus → `.mkv`). `MediaThumbnailer` renders a poster frame. These operations sit behind
  protocols / injected seams, so the transfer path stays testable against `MockHTTPClient`.
- **Page extraction (yt-dlp)** — `MediaExtractor` (protocol) resolves a *page* URL (a YouTube
  watch page, or another site supported by the bundled yt-dlp version) into its available video/audio
  formats (`ExtractedMedia` / `ExtractedFormat`). It is a **resolver / decipher oracle, not a
  downloader**: the production `YtDlpExtractor` spawns the bundled, code-signed `yt-dlp` binary
  with `-J` (dump-single-json). It may contact the submitted page and related service endpoints to
  resolve metadata and media URLs, then prints JSON to stdout; it never touches the destination or
  transfers the selected media payload. CloakDrop's own segmented engine does those payload bytes,
  so pause/resume, persistence, and the sandbox story stay ours. Subprocess spawning is behind
  `ProcessRunning` (`SystemProcessRunner` in prod, captured to temp files with a hard timeout so a
  multi-MB dump can't deadlock a pipe; a mock in tests), and `ExtractedMedia+Mapping` folds the
  result into the existing `MediaStream`/`MediaPlan` quality picker. `locate(in:)` feature-detects
  a runnable binary at launch so the UI only offers extraction when it can actually work — mirroring
  `FFmpegMuxer.locate`. The bundled yt-dlp is refreshed through normal app updates.

## Concurrency model

- **No shared mutable state across threads.** Mutable coordination lives in the `DownloadManager`
  actor; per-download mutable state lives in its `DownloadTask` actor.
- **Connection selection is explicit and bounded.** Automatic mode keeps the configured default for
  ordinary files and scales large files toward the configured maximum while respecting minimum
  segment size. A per-download manual choice overrides the automatic target but is still clamped to
  the resource and global maximum. The choice persists across scheduling and relaunch.
- **Parallel segments** run through a rolling `withThrowingTaskGroup` window inside the task. It
  launches no more than the current connection budget—even when a resumed segment table contains
  old work-stealing tails—and feeds pending segments into slots as they finish. Each child opens its
  **own** `FileHandle` into the shared sparse part file at a disjoint offset.
- **Dynamic re-splitting (work-stealing).** When a worker finishes its region while others are
  still going, it steals the largest remaining tail from a straggler — splitting that segment and
  taking over the back half when enough useful work remains, reducing the slow-tail period without
  exceeding the connection budget.
- **Pause/cancel** is cooperative: the manager sets a stop reason then cancels the task's
  enclosing `Task`; structured cancellation propagates to the segment children, which unwind and
  let the task persist a clean paused/canceled state.
- **UI isolation:** `AppModel` is `@MainActor @Observable`. It consumes the engine's event stream
  (the consuming `Task` inherits the main actor) and mirrors events into observable state. Live
  progress (≈10/sec) flows through a separate `progress` dictionary so it never thrashes the
  status-level `downloads` array or the database.

## Data flow for a download

1. UI builds a `DownloadRequest` → `DownloadManager.add`.
2. Manager creates a `Download`, persists it, emits `.downloadAdded`, and schedules it if a queue
   slot is free.
3. `DownloadTask.run`: probe (best-first across mirrors when a Metalink supplied them) → choose the
   connection budget → plan segments (or a single stream) → size the `.cdpart` file exactly → transfer
   through the bounded rolling scheduler with retry/resume + mirror failover + work-stealing +
   throttle → emit throttled `.progress` events and periodically persist. If a server's ranged
   response is invalid, discard the coherent staging set and retry once as a whole stream.
4. On ordinary-file completion: when enabled, resolve and verify any checksum **against `.cdpart`** →
   move staging to an unoccupied destination without replacing an existing file/directory → optionally
   (default on) stamp Gatekeeper quarantine → optionally extract ZIP → assess the local code signature → optionally build the
   Provenance Receipt → mark completed and emit the update. Media plans assemble/remux their persisted
   `.cdparts` through their separate finalize path. The manager fills the freed queue slot; when all
   work has drained it emits `.allDownloadsCompleted`, and `AppModel` applies the configured all-done
   action once for that work cycle.

## Persistence & resume

Ordinary-file bytes are written into a single sparse `*.cdpart` file; each segment owns a contiguous
byte region. The known-size staging file is resized exactly in both directions, preventing stale
trailing bytes from an older attempt. Per-segment `downloadedBytes` is persisted, so a resume request
starts at `segment.start + downloadedBytes`. This makes **resume survive force-quit and reboot**—
verified by an integration test that pauses mid-flight, discards the manager, and resumes a brand-new
manager from the same store and part file. Suggested names are reduced to safe basenames and reserved
case-insensitively against cataloged downloads and existing destination entries. Distinct catalog
names imply distinct staging paths for concurrent adds; an orphan same-name part file is resized
exactly before reuse. Finalization still refuses replacement if another process wins the remaining
race.

## Sandbox

The app is fully sandboxed. The default Downloads folder is covered by entitlement; user-chosen
folders are persisted as **security-scoped bookmarks** and activated (`SecurityScope`) for the
duration of each transfer.

## Capture

The primary capture surface is the **built-in browser** (`App/Features/Browser/`): a WKWebView the
user opens from the app, navigates anywhere, and grabs media from. A collector script injected into
every frame (document-start, page world) reports raw sightings — resource URLs, response headers,
`<video>`/`<audio>` elements (including players inside open *and closed* shadow roots, via a
wrapped `attachShadow`), MediaSource signals, SPA navigations — to the app, where the pure
`MediaSniffer` (pure and DOM-free, run against a captured fixture test
corpus) classifies, dedupes, and ranks them into the shelf. The classifier is also a *filter*:
ad-network hosts, analytics beacons, adaptive-stream chunks (segment extensions, byte-windowed
`bytestart=`/`range=` fetches), and UI sound effects never surface as grabs. DRM is flagged only on
real engagement — `setMediaKeys` with keys, or an `encrypted` media event — never on the capability
probes players run against clear content. A sniffed stream is shown and saved under the **page
title** (its URL only names a manifest); the engine appends the container extension once the plan
is known. Grabs and IDM-style download takeovers
become `CapturedDownload`s and route through the same media/add funnels as everything else; every
byte is still fetched by the engine, now carrying the page's referer, real user-agent, and cookies.

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
