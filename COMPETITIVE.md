# CloakDrop — Competitive Landscape & Feature Roadmap

A living comparison of CloakDrop against the three download managers people ask about most —
**IDM** (Internet Download Manager, Windows-only, paid), **FDM** (Free Download Manager,
cross-platform, free), and **JDownloader** (cross-platform, Java, free) — plus the roadmap that
follows from it.

**How to maintain this file:** it is the source of truth for "what we have vs. what they have."
When a feature lands, flip its row in the matrix and check its box in the roadmap. Competitor columns
reflect each product's well-established, stable feature set; re-verify before treating a *new*
competitor feature as gospel. The CloakDrop column is verified against the actual code.

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
| Metalink multi-source + mirror failover | ✅ | ❌ | ⚠️ | ⚠️ |
| Checksum verify + sibling auto-discovery | ✅ | ⚠️ | ⚠️ | ⚠️ |
| FTP / FTPS | ✅ | ✅ | ✅ | ✅ |
| BitTorrent | ❌ | ❌ | ✅ | ❌ |
| **Intake** |
| Browser extensions | ✅ (Safari + Chromium + Firefox) | ✅ | ✅ | ✅ |
| Clipboard monitor / drag-drop | ✅ | ✅ | ✅ | ✅ |
| Batch / pattern add | ✅ | ✅ | ⚠️ | ✅ |
| Link-grabber (paste wall → analyze → pick) | ✅ | ⚠️ | ⚠️ | ✅ (best) |
| Scheduler + recurrence | ✅ | ✅ | ✅ | ✅ |
| Folder watch (job files) | ❌ | ❌ | ❌ | ✅ |
| Page "grab all" (bounded site grabber) | ✅ | ✅ | ❌ | ⚠️ |
| **Media** |
| HLS/DASH grab + mux | ✅ | ⚠️ | ⚠️ | ⚠️ |
| Site video extraction (~1800 sites) | ✅ (yt-dlp) | ⚠️ | ✅ | ✅ |
| **Post / organize** |
| Categories / auto-sort | ✅ | ✅ | ✅ | ⚠️ |
| Smart-rule routing engine | ✅ | ⚠️ | ⚠️ | ✅ (scripter) |
| Duplicate detection | ✅ | ⚠️ | ⚠️ | ⚠️ |
| Archive auto-extraction | ✅ | ⚠️ (zip preview) | ❌ | ✅ |
| Post-download actions (sleep / quit / notify / run) | ✅ | ✅ | ✅ | ✅ |
| Saved credential store (Keychain) | ✅ | — | ✅ | ✅ |
| **Security / privacy** |
| Sandboxed, truly native | ✅ | ❌ | ⚠️ (Qt) | ❌ (Java) |
| No telemetry / no bundled adware | ✅ | ⚠️ | ⚠️ | ❌ (installer PUP) |
| Code-signature / trust assessment | ✅ | ❌ | ⚠️ | ❌ |
| Gatekeeper quarantine flag on saved files | ✅ | n/a | n/a | n/a |
| **Provenance receipt (verified-download record)** | ✅ **unique** | ❌ | ❌ | ❌ |
| Full accessibility (VoiceOver / keyboard) | ✅ | ⚠️ | ⚠️ | ❌ |
| **Remote** |
| Remote / mobile control | ❌ | ❌ | ✅ | ✅ (My.JD) |
| Hoster / premium-account / captcha ecosystem | 🚫 | ❌ | ❌ | ✅ |

> Rows marked ✅ for CloakDrop that were ❌/⚠️ at the start of this effort are being delivered by the
> roadmap below; flip them as each lands. This snapshot reflects the **target** state at the end of
> Phases 1–3 + the unique feature.

---

## Where CloakDrop already leads

Stated plainly so the roadmap doesn't chase parity we already have:

- **Truly native macOS** — Liquid Glass, full light/dark, VoiceOver + full-keyboard access. IDM is
  Windows-only; FDM's Mac app is Qt; JDownloader is Java.
- **Privacy** — no telemetry, no accounts, no phone-home, no installer adware. A real differentiator
  against JDownloader's PUP-bundling installer and FDM's 2023 macOS supply-chain incident.
- **Metalink multi-source with mirror failover**, **checksum sibling auto-discovery**, and
  **code-signature trust assessment** — mostly ahead of all three.
- **yt-dlp breadth** (~1800 sites) — matches or beats their video grabbing.
- Core transfer engine (multi-segment + dynamic work-stealing) is at parity with all three.

---

## Roadmap

Each item follows the architecture rule: model in `DownloadModels` → logic in `DownloadEngine` /
`AppModel` behind protocols with tests → thin SwiftUI. Every user-facing string is localized ×10.

### Foundation
- [x] **Bandwidth limiter correctness** — global + per-download caps now hold under concurrency
  (GCRA virtual-clock; aggregate-throughput test).

### Phase 1 — Quick, high-value polish
- [ ] **Post-download actions** — when a queue finishes: sleep display / quit app / play sound /
  post notification / run a Shortcut. (Full system shutdown is sandbox-blocked; the rest are clean.)
- [ ] **Gatekeeper quarantine flag** — apply `com.apple.quarantine` to completed files so Gatekeeper
  vets them on first open. Pairs with the existing trust assessment. *Highest security ROI.*
- [ ] **Time-of-day bandwidth profiles** — throttle to X between set hours, unlimited otherwise.
  Composes the existing scheduler + limiter.
- [ ] **FTP / FTPS** — native client over Network.framework (passive mode, `REST` resume, `SIZE`,
  TLS via `NWProtocolTLS`). No bundled library — extends the `HTTPClient`/transfer seam.

### Phase 2 — Convenience parity
- [ ] **Archive auto-extraction** — auto-unpack on completion (ZIP native via `libarchive`/system;
  RAR/7z evaluated separately to honor the no-bundled-tools preference).
- [ ] **Keychain credential store** — host→credentials vault for site auth + proxy, replacing the
  current plaintext storage (already flagged in `ProxyConfiguration`).

### Phase 3 — Intake power
- [ ] **Link-grabber panel** — paste a wall of mixed links → dedupe / analyze / select → enqueue.
  Builds on batch + pattern expansion. (No container files / hoster baggage — see out-of-scope.)
- [ ] **Bounded page "grab all"** — the browser extension already sniffs page media; extend to
  "download everything on this page matching a filter (all images / PDFs / regex)." Single
  user-opened page only — no open-ended crawler, keeping it privacy-safe.

### In place of Phase 4 — a truly unique differentiator (no bundled tools)
- [ ] **Provenance Receipt** — see below. Recommended pick.

---

## The unique feature — Provenance Receipt

**One-liner:** every completed download gets a local, shareable *verified-download record* — a
cryptographic provenance card no other download manager produces.

**Why it's the right pick:**
- **Genuinely unique** — IDM/FDM/JDownloader verify a checksum at best; none produce a provenance
  record combining source, transport, integrity, and code-signing trust.
- **Zero bundled tools** — pure CryptoKit + Security + Network frameworks CloakDrop already uses.
- **On-device / privacy-first** — the record never leaves the Mac unless the user exports it.
- **Compounds existing strengths** — reuses `ChecksumVerifier`, `SignatureAssessment`/`TrustLevel`,
  Metalink multi-source agreement, and redirect/TLS metadata already flowing through the engine.

**What the receipt captures (all already observable in the transfer path):**
- Source URL(s) and the final URL after redirects; every Metalink mirror that served bytes.
- TLS: cert issuer / chain summary for each host.
- Integrity: the whole-file SHA-256, plus whether it matched a supplied/auto-discovered checksum and
  (for Metalink) whether independent mirrors agreed byte-for-byte.
- Code signing: for `.app`/`.dmg`/`.pkg`, the notarization / Developer-ID / ad-hoc / unsigned verdict.
- A single **trust verdict** rolled up from the above, shown in the inspector and exportable as a
  signed JSON/`.txt` receipt.

**Alternatives considered** (kept here for the record):
- *Watch & auto-refresh a URL* — poll ETag/Last-Modified, re-download when a file changes (nightly
  builds, datasets). Useful, uses the scheduler, but less differentiated.
- *LAN segment sharing* — share partial segments between your own Macs on the LAN. Unique and
  privacy-clean, but complex and needs a second device.
- *Adaptive quiet-hours* — learn fast/slow network windows from local `SpeedSampler` history and
  suggest optimal download times. Nice, but thinner than the receipt.

---

## Deliberately out of scope

Saying no is part of the strategy:

- **Hoster / premium-account / captcha / reconnect / waiting-time ecosystem** (JDownloader's core) —
  piracy-adjacent, requires phone-home, and is hostile to the sandbox and App Store. Skipping it is a
  *positioning strength*.
- **Container files (DLC / CCF / RSDF)** and **folder-watch of `.crawljob`/`.dlc`** — only useful
  with the above. Skip.

## Strategic forks — deferred (need a product decision)

- **BitTorrent** (only FDM has it) — the biggest single category we lack, but a large build; DHT/peer
  swarms widen the privacy surface and complicate the sandbox / App Store story. Lean: defer, or a
  separate opt-in module later.
- **LAN-only remote control** — can be done privacy-cleanly (Bonjour, local-network only, opt-in, no
  cloud) as a differentiator vs. FDM/JD's cloud remotes. Medium-large; revisit after Phase 3.
