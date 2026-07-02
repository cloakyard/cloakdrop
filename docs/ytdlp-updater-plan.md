# yt-dlp updater — design plan

**Status:** proposal (not yet implemented) · **Owner:** engine · **Related:** `scripts/fetch-ytdlp.sh`, `YtDlpExtractor`, `MediaExtractor`

## Why we need it

yt-dlp is CloakDrop's decipher oracle for YouTube + ~1800 sites. It is **version-pinned** (`YTDLP_VERSION` in `fetch-ytdlp.sh`) and baked into the app bundle at build time. YouTube changes its signature/streaming plumbing every few weeks, and each change needs a newer yt-dlp. Today the only fix is: bump the pin → rebuild → re-release the whole app. That means a broken YouTube grab for every user until the next app release. We want CloakDrop to refresh yt-dlp **without an app update**.

## Why it's hard (the three real constraints)

1. **The bundle is read-only and code-signed.** The onedir tree lives at `CloakDrop.app/Contents/Resources/yt-dlp/`. A sandboxed app cannot write inside its own bundle, and any byte changed there **breaks the app's code signature** → Gatekeeper kills the app. So we can never update in place.
2. **A sandboxed parent can only spawn `inherit`-entitled children.** The bundled `yt-dlp` runs because it's signed with `app-sandbox + inherit + disable-library-validation`. A `yt-dlp_macos.zip` pulled from GitHub carries **none of those entitlements**, so it will not run as our child until it is **re-signed** — and re-signing a downloaded native binary at runtime is the crux of the difficulty.
3. **Privacy is a hard constraint.** The only permitted egress is user-initiated download URLs (+ a user proxy). A silent "phone home to GitHub on launch" updater **violates this**. The updater must be **user-initiated or explicit opt-in**, never a background ping by default.

## Key insight: two update granularities

A yt-dlp release is really two parts:

- **The native runtime** — `_internal/` (the Python interpreter, `Python.framework`, C extensions like `curl_cffi`). This is what's code-signed and sandbox-sensitive. It changes **rarely**.
- **The extractor code** — the `yt_dlp` Python package (pure Python, no native code). This is what breaks when YouTube changes, and what a fix almost always touches. yt-dlp ships this as a self-contained **zipapp** (the plain `yt-dlp` file, ~3 MB, runs on any Python 3.9+).

**The frequently-changing part carries no native code and needs no signing.** That reframes the whole problem.

## Recommended approach: zipapp-first, full-tree fallback

### Tier 1 — update the pure-Python zipapp (no re-signing) ← primary path

Run an updated yt-dlp **zipapp** with the **already-bundled, already-signed interpreter**:

```
Contents/Resources/yt-dlp/_internal/.../python3   <container>/yt-dlp/yt-dlp.zipapp  -J <url>
```

- Download only the plain `yt-dlp` zipapp (not `yt-dlp_macos.zip`) into the sandbox container.
- The hardened runtime restricts loading unsigned **Mach-O**, not interpreting `.py`/zipapp data. A signed interpreter executing downloaded Python source is normal Python behaviour — **no re-sign needed**. Third-party runtime deps resolve against the bundled `_internal` via `sys.path`.
- Covers the overwhelming majority of real breakages (extractor logic), which is exactly the case we care about.

> **Spike required before committing:** confirm the PyInstaller-frozen interpreter can be invoked to run an *external* zipapp with the right `PYTHONHOME`/`sys.path` (base_library.zip + `_internal`), in-sandbox. If the frozen bootstrap makes this impractical, fall through to Tier 2. This is the one unknown that gates the recommendation.

### Tier 2 — update the whole onedir tree (with runtime re-sign) ← fallback

When a bump needs a newer interpreter or native dep:

- Download `yt-dlp_macos.zip` → container → unpack → thin arm64 → **normalize `Python.framework` symlinks** → **ad-hoc re-sign the tree with `YtDlpHelper.entitlements`** (spawn `/usr/bin/codesign --force --sign - --entitlements … `, deepest-first — the exact recipe `fetch-ytdlp.sh` already encodes, run at runtime).
- Risk: spawning `codesign` from inside the sandbox is unproven here and Apple-version-fragile. Treat Tier 2 as opt-in and smoke-test hard.

### Common infrastructure (both tiers)

- **Storage:** installs live in the writable container — `~/Library/Containers/com.cloakyard.cloakdrop/Data/Library/Application Support/CloakDrop/yt-dlp/<version>/`, with a `current` symlink/pointer.
- **`YtDlpExtractor.locate()` precedence:** newest *valid* container install → else the bundled copy. Bundle is always the floor, so a bad update can never brick extraction.
- **Verification:** SHA-256 against the release's `SHA2-256SUMS`; refuse anything unverified (mirrors the fetch script). Fetch only from `github.com/yt-dlp/yt-dlp/releases` over HTTPS.
- **Smoke test before switch:** new install must pass `--version` + a canned `-J` probe before the `current` pointer flips. Keep the previous version for one-step **rollback**.
- **User control & privacy:** a Settings ▸ Extractor row showing *bundled version* / *installed version* / *latest available*, a manual **"Check for updates"** button, and an explicit opt-in **"Check automatically (weekly)"** toggle that is **off by default**. All version checks are user-initiated or opted-into — no silent pings.

## Component sketch

- `protocol YtDlpUpdating` (engine, UI-agnostic): `checkLatest()`, `install(version:)`, `rollback()`, `currentInstall()`. Behind a protocol with a mock, like `MediaExtractor`.
- `YtDlpInstall` value type: version, path, kind (`.zipapp` / `.onedir`), installedAt.
- `YtDlpExtractor.locate(in:)`: extend to consult the container store first.
- App surface: `AppModel` intents (`checkForExtractorUpdate()`, `installExtractorUpdate()`), state (`extractorUpdateStatus`), and a Settings ▸ Extractor section. Strings localized ×10.
- Tests: mock the GitHub fetch + checksum + process runner; assert precedence, checksum rejection, rollback, and locate() fallback. No network in tests.

## Phasing

1. **Now (zero code):** keep the manual pin-bump path documented in `fetch-ytdlp.sh`. Baseline.
2. **Spike:** validate Tier-1 zipapp-with-bundled-interpreter in-sandbox. Go/no-go on the primary path.
3. **Tier 1:** implement zipapp update + container precedence + checksum + rollback + manual "Check for updates" UI.
4. **Tier 2:** full-tree re-sign fallback for runtime bumps (only if a bump ever needs it).
5. **Generalize:** the same container-install + precedence infra later covers **ffmpeg** (same read-only-bundle constraint).

## Open questions

- Does the frozen interpreter cleanly run an external zipapp in-sandbox? (Tier-1 gate.)
- Can `/usr/bin/codesign` ad-hoc-sign inside our sandbox + hardened runtime? (Tier-2 gate.)
- Do we pin to a known-good yt-dlp version list we curate, or always take "latest"? (Trust vs freshness — leaning curated-latest with checksum.)
- For a notarized Developer-ID release, does download-then-execute-updated-code raise any notarization/policy concern? (Tier 1 = interpreting data, should be fine; confirm.)
