# CloakDrop — Competitive Landscape & Feature Roadmap

A living comparison of CloakDrop against the three download managers people ask about most —
**IDM** (Internet Download Manager, Windows-only, paid), **FDM** (Free Download Manager,
cross-platform, free), and **JDownloader** (cross-platform, Java, free) — plus the roadmap that
follows from it.

**How to maintain this file:** it is the source of truth for "what we have vs. what they have."
When a feature lands, flip its row in the matrix and check its box in the roadmap. Competitor columns
reflect each product's well-established, stable feature set; re-verify before treating a *new*
competitor feature as gospel. The CloakDrop column is verified against the actual code.

**Competitor snapshot (re-verified 2026-07):** IDM **6.43** — mature, effectively maintenance-mode
(2024–2026 releases are bug fixes + browser-interception patches, no new features). FDM **6.33**
(libtorrent engine; proprietary since v5). JDownloader **2.0** on rolling per-plugin auto-update
(~110 host plugins). Parity is now the *baseline* — the interesting question this revision asks is
**where the white space is**, not where we're behind.

Legend: ✅ full · ⚠️ partial/limited · ❌ none · 🚫 deliberately out of scope

---

## Feature matrix

| Feature | CloakDrop | IDM | FDM | JDownloader |
|---|:--:|:--:|:--:|:--:|
| **Transfer** |
| Multi-segment | ✅ (8 + work-stealing) | ✅ (≤32) | ✅ | ✅ |
| Resume across reboot | ✅ | ✅ | ✅ | ✅ |
| Auto-retry / net-drop recovery | ✅ | ✅ | ✅ | ✅ |
| Bandwidth limit — global **and** per-download | ✅ | ✅ | ✅ | ✅ |
| Time-of-day speed scheduling | ✅ | ⚠️ | ✅ | ⚠️ |
| Metalink multi-source + mirror failover | ✅ | ❌ | ⚠️ (multi-mirror) | ⚠️ |
| FTP / FTPS | ✅ | ✅ | ✅ | ✅ |
| Play / preview while downloading | ❌ | ❌ | ✅ (seq. torrent) | ⚠️ |
| BitTorrent | ❌ | ❌ | ✅ | ❌ |
| **Integrity & trust** |
| Checksum verify (MD5/SHA) + sibling auto-discovery | ✅ | ❌ | ❌ | ⚠️ (hash, no sibling) |
| Code-signature / trust assessment | ✅ | ❌ | ❌ | ❌ |
| Gatekeeper quarantine flag on saved files | ✅ | n/a | n/a | n/a |
| **Provenance Receipt (verified-download record)** | ✅ **unique** | ❌ | ❌ | ❌ |
| **C2PA / Content Credentials verify on ingest** | ❌ *(white space)* | ❌ | ❌ | ❌ |
| **Intake** |
| Browser extensions | ✅ (Safari + Chromium + Firefox) | ✅ | ✅ | ✅ |
| Browser-download interception (takeover) | ✅ (fail-safe: falls back to the browser) | ✅ | ✅ | ⚠️ |
| Clipboard monitor / drag-drop | ✅ | ✅ | ✅ | ✅ |
| Batch / pattern add | ✅ | ✅ | ⚠️ | ✅ |
| Link-grabber (paste wall → analyze → pick) | ✅ | ⚠️ | ⚠️ | ✅ (best) |
| Deep multi-level site crawler | ⚠️ (bounded, 1 page by design) | ✅ (two-axis depth) | ⚠️ (legacy spider) | ✅ |
| Scheduler + recurrence | ✅ | ✅ | ✅ | ✅ |
| Watch & auto-refresh on server change | ❌ | ✅ (sync queue) | ❌ | ⚠️ |
| Folder watch (job files) | ❌ | ❌ | ❌ | ✅ |
| **Automation** |
| Scripting / automation surface | ⚠️ (planned: App Intents) | ⚠️ (CLI flags) | ✅ (Deno/Python add-ons) | ✅ (Event Scripter, best) |
| Native OS integration (Shortcuts / Siri / Spotlight) | ⚠️ (Shortcut post-action) | ❌ | ❌ | ❌ |
| **Media** |
| HLS/DASH grab + mux | ✅ | ⚠️ (HLS/TS only) | ⚠️ | ⚠️ |
| Site video extraction (~1800 sites) | ✅ (yt-dlp) | ⚠️ | ❌ (YouTube removed '21) | ✅ |
| Media transcription / subtitle generation | ❌ *(white space)* | ❌ | ❌ | ❌ |
| Media-library enrichment (metadata/artwork/subs) | ❌ *(white space)* | ❌ | ❌ | ❌ |
| **Post / organize** |
| Categories / auto-sort | ✅ | ✅ | ✅ | ⚠️ |
| Smart-rule routing engine | ✅ | ⚠️ | ⚠️ | ✅ (scripter) |
| Duplicate detection | ✅ (URL/ETag/content) | ❌ | ❌ | ⚠️ (hash-avoid) |
| Content-addressed library dedup | ❌ *(white space)* | ❌ | ❌ | ❌ |
| Archive auto-extraction (ZIP) | ✅ | ⚠️ (zip preview) | ⚠️ (partial-zip) | ✅ |
| Password-protected / RAR / 7z extraction | ❌ | ❌ | ❌ | ✅ |
| Post-download actions (sleep / quit / notify / run) | ✅ | ✅ | ✅ | ✅ |
| Saved credential store (Keychain) | ✅ | ⚠️ | ✅ | ✅ |
| **Intelligence** |
| On-device AI organize (rename / tag / categorize) | ❌ *(white space)* | ❌ | ❌ | ❌ |
| Network-condition-aware smart scheduling | ⚠️ (net-drop pause) | ⚠️ | ⚠️ | ❌ |
| Built-in speed test (down/up/latency/bufferbloat) | ✅ **unique** | ❌ | ❌ | ❌ |
| Community file-reputation warnings | 🚫 (needs cloud) | ❌ | ✅ | ❌ |
| **Platform / trust posture** |
| Sandboxed, truly native | ✅ | ❌ | ⚠️ (Qt) | ❌ (Java) |
| No telemetry / no bundled adware | ✅ | ⚠️ | ⚠️ | ❌ (installer PUP) |
| Full accessibility (VoiceOver / keyboard) | ✅ | ⚠️ | ⚠️ | ❌ |
| **Remote** |
| Remote / mobile control | ❌ | ❌ | ✅ (self-hosted HTTP) | ✅ (My.JD cloud) |
| Hoster / premium-account / captcha ecosystem | 🚫 | ❌ | ❌ | ✅ |

---

## What we're missing (honest gaps)

Parity items competitors have that we don't. Ranked by whether they're worth chasing:

**Worth doing**
- **Password-protected + RAR/7z extraction** (JD leads). We do ZIP natively; RAR/7z need a bundled
  tool (`unar`/`7-Zip` lib) — the one place bundling might be justified. Password-protected ZIP we
  *can* do natively today.
- **Watch & auto-refresh on server change** (IDM's synchronization queue). Re-fetch when a remote
  file's ETag/Last-Modified changes — nightly builds, datasets, feeds. Pure scheduler + `probe`; no
  new dependency. *(This is on the unique-features list below, expanded into feed subscriptions.)*
- **An automation surface** (JD's Event Scripter, FDM's Deno/Python add-ons). We have none. The
  *native* answer — App Intents / Shortcuts — is both a gap-closer and a differentiator (below).

**Maybe / later**
- **Deep multi-level site crawler** (IDM two-axis, JD). We deliberately do single-page "grab all"
  (no crawler) for scope/safety. A *bounded, opt-in* depth-2 crawler with domain scoping is the most
  we'd want — full-site mirroring is a different product.
- **Play / preview while downloading** (FDM). Sequential media fetch + Quick Look preview of the
  in-progress `.cdpart`. Nice, medium effort.
- **Remote control** (FDM self-hosted HTTP, JD cloud). A privacy-clean **LAN-only** remote (Bonjour,
  no cloud) is the only version consistent with our posture. Medium-large; still deferred.

**Deliberately not chasing**
- **BitTorrent** (FDM) — biggest single gap, but a large build that widens the privacy/sandbox
  surface. Deferred as an opt-in module at most.
- **Multi-host / premium-account / captcha ecosystem** (JD) — piracy-adjacent, needs phone-home,
  hostile to the sandbox. Out of scope *by design* (see below).
- **Community file-reputation** (FDM) — requires a central database and phone-home. Against our
  posture; skip.
- **Folder-watch job files** (JD `.crawljob`) — only useful with the hoster ecosystem. Skip.

---

## Where CloakDrop already leads

Stated plainly so the roadmap doesn't chase parity we already have:

- **Truly native macOS** — Liquid Glass, full light/dark, VoiceOver + full-keyboard access. IDM is
  Windows-only; FDM's Mac app is Qt; JDownloader is Java. This is the *enabler* for everything in the
  next section: only a native app gets Speech, Foundation Models, App Intents, and NWPath for free.
- **Integrity & trust stack** — checksum + sibling auto-discovery, code-signature assessment, and the
  **Provenance Receipt** put us ahead of all three on trust. IDM and FDM don't even do native hashing.
- **Metalink multi-source with mirror failover** — ahead of all three.
- **yt-dlp breadth** (~1800 sites) — matches JD, beats IDM, and FDM dropped YouTube in 2021.
- **Privacy posture is now robust** — no telemetry, accounts, or phone-home; sandboxed; credentials in
  the Keychain. Treat this as *table stakes we've already met*, not the headline. It stops being a
  feature to build and becomes a **constraint that shapes** the features below (on-device, no cloud).

---

## The opportunity — advanced & unique features

The parity race is over; this is where CloakDrop stops matching and starts leading. Every item is
**on-device, private, and needs no bundled tool** — each is unclaimed by IDM/FDM/JDownloader and most
leans on a macOS-26 framework a cross-platform Java/Qt/Electron app simply can't reach. Ranked.

### Tier 1 — flagship (build next)

**1. Content Credentials (C2PA) verification on ingest — the inbound twin of the Provenance Receipt.**
The C2PA / Content Credentials standard (spec v2.2, **May 2025**) embeds a cryptographically signed,
tamper-evident provenance manifest inside media — and it **verifies fully offline, no central lookup**.
Cameras, Adobe, and the major AI image generators now emit it. **No download manager reads, validates,
or displays it.** CloakDrop should validate a file's Content Credentials the moment it lands, show
"signed by X, edited by Y, AI-generated: yes/no," **fold the verdict into the Provenance Receipt**, and
*preserve* the manifest through mux/convert (where we currently risk stripping it).
- *Why unique:* zero competitors; the standard is real and shipping upstream, only DM support is the gap.
- *Why us:* it's the exact complement to our existing receipt — we already own the trust UI (`TrustLevel`,
  `SignatureAssessment`). Verification is pure CryptoKit/Security, offline, sandbox-clean.
- *Effort:* medium (a C2PA manifest parser + signature chain validation; model in `DownloadModels`,
  verdict into `ProvenanceReceipt`).

**2. On-device media intelligence — transcripts, chapters & subtitles for anything you grab.**
After a HLS/DASH/yt-dlp media grab, run Apple's **on-device Speech framework** (the macOS-26
`SpeechAnalyzer`/`SpeechTranscriber`) to produce a transcript, auto-chapters, and a sidecar `.srt`, then
index it so downloaded media is **full-text searchable in Spotlight**. No upload, no API key.
- *Why unique:* no DM does speech-to-text; niche yt-dlp GUIs only *pass through* yt-dlp's subtitle flag.
- *Why us:* we already own the finished media file, the poster-frame thumbnailer, and the mux pipeline —
  transcription is one more post-process step. Private by construction (on-device).
- *Effort:* medium; highest "wow" per line of code.

### Tier 2 — strong differentiators

**3. Shortcuts / App Intents automation surface — the native answer to Event Scripter.**
Expose the core verbs — *Download URL*, *Grab links from page*, *Get Provenance Receipt*, *Wait for
download* — as **App Intents**, so users script CloakDrop from Shortcuts, Spotlight, the menu bar, and
Siri, and chain it with every other app on the Mac.
- *Why unique:* JD's Event Scripter (Java) and IDM's CLI are powerful but clunky and non-native; **none
  integrate with macOS Shortcuts**. This closes our biggest automation gap *and* leapfrogs it, sandbox-clean.
- *Why us:* App Intents is native, first-party, and safe inside the sandbox (no arbitrary shell like
  Event Scripter). We already have the intents internally — this is surfacing them.
- *Effort:* medium; unusually high leverage.

**4. On-device AI organize — private auto-rename, tag & categorize.**
Use the macOS-26 **Foundation Models** framework (on-device Apple Intelligence LLM) to propose a clean
filename, a category, and tags from the page title + content + Content Credentials — e.g.
`dQw4w9.mp4` → `Rick Astley — Never Gonna Give You Up (1080p).mp4`, auto-filed under *Music Videos*.
- *Why unique:* the only "AI download manager" claims in the market are cloud/marketing vaporware. A
  **private, local** model doing it is unclaimed.
- *Why us:* the model is on-device and free on our target OS; it plugs straight into `SmartRuleEngine`
  and `FileNaming` as a suggestion source. Privacy posture makes this the *honest* way to ship AI.
- *Effort:* medium.

**5. Network-condition-aware smart scheduling.**
Auto-defer big or metered transfers to the right moment using real OS signals: `NWPath.isExpensive` /
`isConstrained` (cellular/hotspot/Low-Data), power state + charging, `ProcessInfo.thermalState`, and our
own `SpeedSampler` history of fast/slow windows. "Download over Wi-Fi while charging," "pause on
tethering," "grab the 4 GB ISO at 3 a.m. when the pipe is idle."
- *Why unique:* IDM's sync queue and blog-ware "AI scheduling" don't use live device signals; a native
  app does this categorically better than a JVM/Electron one.
- *Why us:* we already have `SpeedSampler` + `NetworkMonitor`; this is a policy layer on top.
- *Effort:* small-to-medium.

### Tier 3 — compounding / opportunistic

**6. Signed, shareable, re-verifiable Provenance Receipt.** Sign the receipt with a device key so a
receipt handed to someone else is tamper-evident and another CloakDrop can re-verify it — turning our
unique record into a portable trust artifact. Natural bridge to C2PA (#1).

**7. Content-addressed library dedup.** Extend `DuplicateDetector` into a hash-indexed local library:
instant "you already have this file" across all history, and never store the same bytes twice. **Even
JDownloader lacks true content dedup.**

**8. Watch & auto-refresh + feed subscriptions.** Poll ETag/Last-Modified and re-download when a remote
file changes; subscribe to an RSS/podcast feed and auto-grab new enclosures. Closes the IDM sync-queue
gap and adds the automation feeds none of them do cleanly. Pure scheduler + `probe`.

---

## Shipped — the current unique feature: Provenance Receipt

**One-liner:** every completed download gets a local, shareable *verified-download record* — a
cryptographic provenance card no other download manager produces.

**What the receipt captures (all already observable in the transfer path):**
- Source URL(s) and the final URL after redirects; every Metalink mirror that served bytes.
- TLS: cert issuer / chain summary for each host.
- Integrity: the whole-file SHA-256, plus whether it matched a supplied/auto-discovered checksum and
  (for Metalink) whether independent mirrors agreed byte-for-byte.
- Code signing: for `.app`/`.dmg`/`.pkg`, the notarization / Developer-ID / ad-hoc / unsigned verdict.
- A single **trust verdict** rolled up from the above, shown in the inspector and exportable as a
  `.txt`/JSON receipt.

**The natural next step** is inbound provenance — reading **C2PA Content Credentials** the publisher
already embedded (Tier 1, #1) — so the receipt reflects not just *how we fetched it* but *where the
content itself came from*.

---

## Delivered so far

Each item followed the architecture rule: model in `DownloadModels` → logic in `DownloadEngine` /
`AppModel` behind protocols with tests → thin SwiftUI. Every user-facing string is localized ×10.

- [x] **Bandwidth limiter correctness** — global + per-download caps hold under concurrency (GCRA
  virtual-clock; aggregate-throughput test). *Fixed a real bug: N connections each ran at ~full rate.*
- [x] **Post-download actions** — notify / quit / run a Shortcut (sandbox-clean, via `shortcuts://`).
- [x] **Gatekeeper quarantine flag** — `com.apple.quarantine` on completed files.
- [x] **Time-of-day bandwidth profiles** — `BandwidthSchedule`, re-applied each minute, wraps midnight.
- [x] **FTP / FTPS** — native client over Network.framework (EPSV/PASV, `REST` resume, `SIZE`, implicit
  TLS). No bundled library. Verified with a loopback FTP server.
- [x] **Archive auto-extraction** — native ZIP (`Compression.framework`, Zip-Slip + bomb guarded).
- [x] **Keychain credential store** — proxy password + per-site HTTP/FTP credentials in the Keychain.
- [x] **Link-grabber panel** — paste/import a wall of links → dedupe / pattern-expand → pick.
- [x] **Bounded page "grab all"** — `PageLinkExtractor`, single page only (no crawler).
- [x] **Provenance Receipt** — per-download verified record, inspector + export.
- [x] **Localization** — `validate_localizations.py`: 340 strings × 10 languages.
- [x] **Built-in speed test** — speedometer dials in Settings ▸ Speed Test (+ menu-bar shortcut):
  multi-connection download/upload with warm-up exclusion, idle + loaded latency (bufferbloat),
  jitter. Cloudflare default, Ookla optional; strictly user-initiated (privacy docs updated).
  No competitor has one.

---

## Deliberately out of scope

Saying no is part of the strategy:

- **Hoster / premium-account / captcha / reconnect / waiting-time ecosystem** (JDownloader's core) —
  piracy-adjacent, requires phone-home, and is hostile to the sandbox and App Store. Skipping it is a
  *positioning strength*.
- **Community file-reputation database** (FDM) — requires a central server and phone-home. Against our
  privacy posture.
- **Container files (DLC / CCF / RSDF)** and **folder-watch of `.crawljob`/`.dlc`** — only useful with
  the hoster ecosystem. Skip.

## Strategic forks — deferred (need a product decision)

- **BitTorrent** (only FDM has it) — the biggest single category we lack, but a large build; DHT/peer
  swarms widen the privacy surface and complicate the sandbox / App Store story. Lean: defer, or a
  separate opt-in module later.
- **LAN-only remote control** — privacy-clean (Bonjour, local-network only, opt-in, no cloud) as a
  differentiator vs. FDM's self-hosted HTTP and JD's cloud remote. Medium-large; revisit after Tier 1–2.
- **RAR / 7z extraction** — the one case where bundling a tool (`unar`) might be justified; ZIP
  (incl. password) stays native. Decide when a user actually asks.
