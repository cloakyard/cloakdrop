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
│  ── HTTPClient (protocol) → URLSessionHTTPClient / MockHTTPClient                     │
│  ── SegmentPlanner · BandwidthLimiter · ChecksumVerifier · NetworkMonitor            │
└──────────────────────────────────────────────────────────────────────────────────┘
```

## Modules

### `DownloadModels`
Pure, `Sendable` value types with **no dependencies**: `Download`, `DownloadSegment`,
`DownloadStatus`, `DownloadQueue`, `EngineSettings`, `FileCategory`, `ChecksumExpectation`,
`SmartFilter`, `DownloadRequest`, `DownloadProgress`, errors. Also the adaptive-streaming model
(`MediaStream` → `MediaVariant` → `MediaSegment`, plus tracks/init/encryption) with the I/O-free
`HLSParser` and `DASHParser`; the checksum-sibling logic (`ChecksumDiscovery`); and the capture
payload (`CapturedDownload`) and stdio framing (`NativeMessaging`) shared by every intake path.
Because they're plain values, they cross actor boundaries freely and are trivial to test. The
on-device *intake intelligence* lives here too, all pure and I/O-free: `LinkPreview` (the pre-flight
result), `DuplicateDetector`/`DuplicateCandidate` (content-addressed duplicate detection by URL /
same-origin ETag / completed name+size), `SignatureAssessment` + `TrustLevel` (the unified trust
signal from checksum + code signature), and the smart-rule model (`SmartRule`, `SmartRuleCondition`,
`SmartRuleAction`, `RuleInput`) with its evaluator `SmartRuleEngine`.

### `DownloadPersistence`
A `DownloadStore` **protocol** (so the engine can be tested against an in-memory fake) and a
`GRDBDownloadStore` implementation. Each `Download` is persisted as a JSON payload alongside
indexed scalar columns (status/queue/category/order) — a stable schema that stays queryable as
the model evolves. Migrations via GRDB's `DatabaseMigrator`.

### `DownloadEngine`
The concurrency core. Everything mutable is actor-isolated.

- **`DownloadManager`** (actor) — the single entry point. Owns the catalog of downloads and
  queues, enforces per-queue concurrency, persists state, and drives one `DownloadTask` per
  active transfer. Publishes an `AsyncStream<EngineEvent>` the UI renders. Subscribes to
  `NetworkMonitor` to auto-pause on connectivity loss and auto-resume on return.
- **`DownloadTask`** (actor, one per download) — probes the server, plans segments, transfers
  them concurrently, throttles, streams progress, then finalizes and verifies. The concurrent
  segment workers are **non-isolated free functions** (`runSegment`) that report byte deltas
  back through actor methods, so the authoritative state mutates serially and race-free.
- **`HTTPClient`** (protocol) — `URLSessionHTTPClient` (delegate-driven, chunked `Data`,
  cancellable) in production; `MockHTTPClient` (in-memory, supports Range, injectable drops)
  for tests and previews.
- **Pure helpers** — `SegmentPlanner` (segmentation math), `BandwidthLimiter` (token bucket),
  `BackoffPolicy` (retry timing), `ChecksumVerifier` (CryptoKit), `SpeedSampler` (rate
  estimate). Each is isolated from I/O so it is exhaustively unit-tested.
- **Intake seams** — `LinkInspector` turns one `HTTPClient.probe` into a `LinkPreview` (final URL
  after redirects, size, range-support, MIME, ETag, connection estimate) for the add sheet's live
  pre-flight; `CodeSignatureInspector` (protocol → `SecCodeSignatureInspector`, Security framework,
  in-process, no network) assesses a finished `.app`/`.dmg`'s code signature in `DownloadTask.finalize`.
  Smart-rule routing is applied in `DownloadManager.add` (folder / queue / speed cap / auto-start).
- **Media** — `MediaResolver` fetches + parses a manifest URL into a ready `MediaPlan`, pairing an
  adaptive video rendition with its separate audio track so a "video" grab always has sound;
  `DownloadTask` grabs the video *and* audio segments over the same engine, decrypting AES-128
  (`AES128`), then muxes and passthrough-remuxes the result into a clean container. The `Remuxer`
  protocol has two backends behind a `CompositeRemuxer` (tries each in order): `AVFoundationRemuxer`
  first — fast, in-process, no dependency, H.264/HEVC + AAC → `.mp4`/`.m4a` — falling back to a
  bundled `FFmpegMuxer` (stream-copy via a `Process`) for the codecs AVFoundation can't carry
  (VP9/AV1/Opus → `.mkv`). `MediaThumbnailer` renders a poster frame; `ChecksumResolver` fetches a
  sibling checksum for auto-verification. All behind protocols / injected, so the transfer path
  stays testable against `MockHTTPClient`.

## Concurrency model

- **No shared mutable state across threads.** Mutable coordination lives in the `DownloadManager`
  actor; per-download mutable state lives in its `DownloadTask` actor.
- **Parallel segments** run as children of a `withThrowingTaskGroup` inside the task. Each child
  opens its **own** `FileHandle` into the shared sparse part file at a disjoint offset, so
  parallel writes never contend.
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
3. `DownloadTask.run`: probe → plan segments (or single-stream fallback) → pre-size the
   `.cdpart` file → transfer segments in parallel with retry/resume + throttle → emit throttled
   `.progress` events and periodically persist.
4. On completion: move part file → destination, verify checksum, mark completed, emit update.
   The manager fills the freed queue slot.

## Persistence & resume

Bytes are written into a single sparse `*.cdpart` file; each segment owns a contiguous byte
region. Per-segment `downloadedBytes` is persisted, so a resume request starts exactly at
`segment.start + downloadedBytes`. This is what makes **resume survive force-quit and reboot** —
verified by an integration test that pauses mid-flight, discards the manager, and resumes a
brand-new manager from the same store and part file.

## Sandbox

The app is fully sandboxed. The default Downloads folder is covered by entitlement; user-chosen
folders are persisted as **security-scoped bookmarks** and activated (`SecurityScope`) for the
duration of each transfer.

## Capture

Every intake path — the `cloakdrop://` URL scheme, the bundled Safari Web Extension, the
Chrome/Edge/Brave/Firefox extension (via the `CloakDropNativeHost` native-messaging helper), the
Share Extension, and the in-process Services item — funnels into one validated `CapturedDownload`
value and one confirm banner. The browser/share extensions hand off **without any browser↔app
network path**: they write the capture as JSON into a shared **App Group** container (`CaptureInbox`)
and post a payload-free Darwin notification; the app drains the inbox on that signal and on launch.
The notification carries no data, and the data never leaves the container both processes are
entitled to. App Groups require a team, so the shared-inbox path lives only in the **Release**
entitlements; Debug builds fall back to the `cloakdrop://` deep link.
