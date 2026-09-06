# Dependency and vendor audit — 6 September 2026

The macOS app's three direct external components already match their latest stable releases. The site now uses the latest updates allowed by its upstream dependency ranges. This does **not** mean every transitive dependency is the newest independent release: TypeScript 7 is outside Astro Check's supported peer range, and the official yt-dlp bundle contains several older runtime components, including OpenSSL with a newer security patch available.

No new third-party application dependencies were introduced. No site deployment, operating system update, or machine-wide package update was performed.

## Direct inventory

| Component | Before | After | Latest stable checked | Evidence / decision |
| --- | --- | --- | --- | --- |
| GRDB.swift | 7.11.1 | 7.11.1 | 7.11.1 | [Official release](https://github.com/groue/GRDB.swift/releases/tag/v7.11.1); revision `b83108d10f42680d78f23fe4d4d80fc88dab3212`. |
| ffmpeg | 9.0.1 | 9.0.1, rebuilt | 9.0.1 | [Official download page](https://ffmpeg.org/download.html); minimal arm64 source build. |
| yt-dlp | 2026.08.19 | 2026.08.19, re-vendored | 2026.08.19 | [Official release](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.08.19); official macOS onedir archive. |
| Astro | 7.3.1 | 7.3.1 | 7.3.1 | [npm registry](https://registry.npmjs.org/astro/latest). |
| @astrojs/sitemap | 3.7.4 | 3.7.4 | 3.7.4 | [npm registry](https://registry.npmjs.org/@astrojs%2Fsitemap/latest). |
| @astrojs/check | 0.9.10 | 0.9.10 | 0.9.10 | [npm registry](https://registry.npmjs.org/@astrojs%2Fcheck/latest). |
| TypeScript | 6.0.3 | 6.0.3 | 7.0.2 | [Official 7.0.2 release](https://github.com/microsoft/TypeScript/releases/tag/v7.0.2). Latest Astro Check requires `^5.0.0 || ^6.0.0`; retained latest supported 6.x. |
| Wrangler | 4.129.0 | 4.129.0 | 4.129.0 | [npm registry](https://registry.npmjs.org/wrangler/latest). |

SwiftUI, AppKit, WebKit, AVFoundation, CryptoKit, Network, Security, and the app's SQLite binding are Apple/system frameworks, not separately vendored packages. GRDB has no additional application package dependency. SwiftPM's existing core `Package.resolved` is now included by a narrow `.gitignore` exception; generated Xcode locks remain ignored. The package's Swift 6 language setting was left intact.

## Site transitive updates

`npm update --ignore-scripts` updated 23 packages installed on this Mac; the lockfile has 37 versioned entry changes when all 15 platform variants of Rolldown's native binding are counted. Changes remained within the ranges selected by their owning packages. For example, the css-select/css-what major changes are dependencies selected by the allowed SVGO update.

| Package | Before | After |
| --- | --- | --- |
| `@astrojs/language-server` | 2.16.13 | 2.16.16 |
| `@jridgewell/sourcemap-codec` | 1.5.5 | 1.6.0 |
| `@oxc-project/types` | 0.143.0 | 0.148.0 |
| `@rolldown/binding-* (15 platform packages)` | 1.2.3 | 1.2.7 |
| `ansi-regex` | 6.2.2 | 6.3.0 |
| `css-select` | 5.2.2 | 6.0.0 |
| `css-what` | 6.2.2 | 7.0.0 |
| `devalue` | 5.9.0 | 5.9.2 |
| `es-module-lexer` | 2.3.1 | 2.3.2 |
| `magic-string` | 1.1.0 | 1.2.3 |
| `p-limit` | 7.3.1 | 7.3.2 |
| `picomatch` | 4.0.5 | 4.0.7 |
| `postcss` | 8.5.26 | 8.5.28 |
| `rolldown` | 1.2.3 | 1.2.7 |
| `svgo` | 4.0.2 | 4.1.0 |
| `tinyexec` | 1.3.0 | 1.3.1 |
| `undici` | 8.10.0 | 8.10.2 |
| `vite` | 8.2.1 | 8.2.2 |
| `vscode-jsonrpc` | 9.0.1 | 9.0.2 |
| `vscode-languageserver-protocol` | 3.18.2 | 3.18.3 |
| `vscode-languageserver-textdocument` | 1.0.12 | 1.0.14 |
| `vscode-languageserver-types` | 3.18.0 | 3.18.3 |
| `vscode-uri` | 3.1.0 | 3.2.0 |

The remaining `npm outdated --all` entries reflect upstream constraints, rather than missed compatible updates. In particular:

- TypeScript 6.0.3 satisfies Astro Check; 7.0.2 does not. Volar's broad peer range does not override Astro Check's stricter range.
- `@types/node` stays 24.13.3 because sitemap restricts it to `^24.0.13`, even though some peers accept 26.4.1.
- Wrangler and Miniflare pin workerd 1.20260903.1, despite the standalone runtime having 1.20260906.1 available. Cloudflare's unenv preset has a broader peer range, but overriding the tested Wrangler/Miniflare runtime pairing is inappropriate here.
- Wrangler pins esbuild 0.28.1, while Astro uses 0.28.2. Miniflare pins sharp 0.35.2, undici 7.29.0, and ws 8.21.0. Their parent versions are current.
- The existing fast-uri 3.1.7 override remains within AJV's major-version contract; latest 4.1.4 is a separate major.
- Other older major versions, including Babel 7 and Astro language server's compiler 2.x, remain within their owning packages' declared ranges. No incompatible blanket overrides were added.

Version facts came from npm's live official registry on the audit date. A clean `npm ci --ignore-scripts` succeeded, `npm ls --all` reported a valid tree, `npm run check` reported **0 errors, 0 warnings, 0 hints across 21 files**, and `npm run build` generated all three static pages. `npm audit --json` reported **zero known vulnerabilities** across 451 lockfile dependency entries (including optional platform packages). This is a database result for that graph and date, not a proof of absence of vulnerabilities.

## yt-dlp runtime inventory and remaining updates

The frozen bundle was identified using its own verbose diagnostic output, Python framework metadata, `.dist-info` metadata, native library version functions, and the release's [default requirements](https://github.com/yt-dlp/yt-dlp/blob/2026.08.19/bundle/requirements/default.txt), [macOS requirements](https://github.com/yt-dlp/yt-dlp/blob/2026.08.19/bundle/requirements/macos.txt), and [macOS curl-cffi requirements](https://github.com/yt-dlp/yt-dlp/blob/2026.08.19/bundle/requirements/macos-curl_cffi.txt). The lock-derived entries below are identified as such; they were not all individually imported from the frozen executable.

| Component | Bundled / upstream release lock | Latest checked | Status |
| --- | --- | --- | --- |
| Python | 3.14.6 | 3.14.7 | Older runtime; [Python releases](https://www.python.org/downloads/). |
| OpenSSL | 3.5.7 | 3.5.8 in 3.5 LTS; 4.0.2 newest series | **Security patch outstanding**; [official releases](https://openssl-library.org/source/). |
| zstd | 1.5.7 | 1.5.7 | Current; [official release](https://github.com/facebook/zstd/releases/tag/v1.5.7). |
| curl-cffi | 0.16.0 | 0.16.3 | Older; [PyPI](https://pypi.org/project/curl-cffi/). |
| websockets | 17.0.1 | 17.1 | Older; [PyPI](https://pypi.org/project/websockets/). |
| charset-normalizer | 3.5.0 (release lock) | 3.5.1 | Older; [PyPI](https://pypi.org/project/charset-normalizer/). |
| idna | 3.18 (release lock) | 3.19 | Older; [PyPI](https://pypi.org/project/idna/). |
| cffi | 2.1.1 (release lock) | 2.1.1 | Current; [PyPI](https://pypi.org/project/cffi/). |
| pycparser | 3.0 (release lock) | 3.0 | Current; [PyPI](https://pypi.org/project/pycparser/). |
| typing-extensions | 4.16.0 (release lock) | 4.16.0 | Current; [PyPI](https://pypi.org/project/typing-extensions/). |
| brotli | 1.2.0 | 1.2.0 | Current; [PyPI](https://pypi.org/project/brotli/). |
| certifi | 2026.07.22 | 2026.7.22 | Current; [PyPI](https://pypi.org/project/certifi/). |
| mutagen | 1.48.1 | 1.48.1 | Current; [PyPI](https://pypi.org/project/mutagen/). |
| pycryptodomex / Cryptodome | 3.23.0 | 3.23.0 | Current; [PyPI](https://pypi.org/project/pycryptodomex/). |
| requests | 2.34.2 | 2.34.2 | Current; [PyPI](https://pypi.org/project/requests/). |
| urllib3 | 2.7.0 | 2.7.0 | Current; [PyPI](https://pypi.org/project/urllib3/). |
| yt-dlp-ejs | 0.8.0 | 0.8.0 | Current; [PyPI](https://pypi.org/project/yt-dlp-ejs/). |
| SQLite in frozen Python | 3.50.4 | 3.53.4 | Older, statically incorporated into `_sqlite3` (verified with `otool`/`nm`); distinct from the app's system SQLite used by GRDB. [Official SQLite download](https://www.sqlite.org/download.html). |

The helper reports **1,744 extractors**. This is an extractor count, not a guarantee that 1,744 sites currently succeed; sites can require login, region access, JavaScript support, or change independently of releases. yt-dlp's upstream build uses PyInstaller 6.22.0 and hooks-contrib 2026.6. Those are build tools for the upstream artifact, not new application dependencies.

OpenSSL 3.5.8 was released on August 25 with security fixes whose highest upstream rating is Moderate. Several affect QUIC servers, CMS/CMP, DTLS, or low-level cipher APIs; full reachability from every supported extractor has **not** been established. This audit does not label 3.5.7 vulnerability-free. See the [OpenSSL 3.5.8 security release notes](https://openssl-library.org/news/openssl-3.5-notes/).

The official stable yt-dlp bundle was retained as a complete tested distribution. Replacing individual native/Python pieces inside a PyInstaller archive would cease to reproduce the signed upstream artifact and risks ABI, resource, or import mismatches. Addressing the remaining runtime updates requires a newer upstream bundle or a separately maintained, pinned, signed custom build with end-to-end extraction tests. This remains an explicit release-hardening follow-up; it was not hidden by a forced version override.

OSV's batch API returned no listed advisories for 15 exact PyPI versions: yt-dlp plus the 14 Python components in the table from curl-cffi through yt-dlp-ejs. This lookup does **not** cover native OpenSSL, system libraries, or future advisories.

### Official newer-channel candidates checked

The latest official nightly and master macOS archives were downloaded to temporary directories, checked against their GitHub release asset SHA-256 digests, unpacked, and launched for local version diagnostics without submitting a page URL. Neither closes the runtime update gap:

| Channel | Latest candidate | Python | OpenSSL | curl-cffi / websockets | Extractors |
| --- | --- | --- | --- | --- | --- |
| [Nightly](https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/tag/2026.08.30.232658) | 2026.08.30.232658 | 3.14.6 | 3.5.7 | 0.16.0 / 17.0.1 | 1,745 |
| [Master](https://github.com/yt-dlp/yt-dlp-master-builds/releases/tag/2026.08.30.140045) | 2026.08.30.140045 | 3.14.6 | 3.5.7 | 0.16.0 / 17.0.1 | 1,745 |

Nightly archive SHA-256: `feafcc525fa6bd8e269348ec75519ba326f4e1e581fe3e5b8b875ad8e5eb3b41`. Master archive SHA-256: `cd3b13cc268ae0d5e9b841370f4b17675cd634e3208d77792c5d4f4dc25e3c70`. Candidate checksum signatures were not separately GPG-verified because neither candidate qualified as a runtime-security upgrade. No installed helper was switched.

The concrete upgrade paths are therefore a new upstream complete bundle with patched runtime components, or an intentionally maintained custom build of the current source with Python 3.14.7, OpenSSL 3.5.8 LTS, current compatible Python packages, and an updated SQLite amalgamation. A custom build would introduce a build dependency/pipeline such as PyInstaller and requires the repository's dependency approval before implementation. It would need frozen-import checks, sandboxed HTTPS extraction, signature checks, and regression testing before replacement of the official bundle.

### Proposed custom runtime, awaiting dependency approval

Approve adding an isolated **build-only** toolchain for the existing yt-dlp helper: **PyInstaller 6.22.0** and **pyinstaller-hooks-contrib 2026.6**, matching the [official pinned build requirements](https://github.com/yt-dlp/yt-dlp/blob/2026.08.19/bundle/requirements/pyinstaller.txt). Pin and hash their required build tools as well (upstream currently specifies altgraph 0.17.5, macholib 1.16.4, packaging 26.3, and setuptools 84.0.0). This does not add a separate helper or application feature.

The implementation would:

1. Keep **yt-dlp source 2026.08.19** pinned. Build its unpacked arm64 runtime with **Python 3.14.7**, **OpenSSL 3.5.8 LTS**, and **SQLite 3.53.4**; retain the established onedir layout required by App Sandbox.
2. Update existing frozen packages to **curl-cffi 0.16.3**, **websockets 17.1**, **charset-normalizer 3.5.1**, and **idna 3.19**. Keep other current packages at the verified versions listed above. Commit exact source/wheel hashes and a component inventory so builds do not resolve floating versions.
3. Verify source signatures/checksums, arm64 architecture, complete native linkage, framework layout, every nested code signature, the final app signature, and frozen imports. Test the build first as an isolated candidate, keeping the existing helper until verification succeeds.
4. Run **sandboxed HTTPS metadata extraction** against local fixtures plus a representative user-approved site matrix; exercise cancellation, timeout, login-cookie forwarding, and failure handling. Prove that extraction creates no selected-media payload and that user configuration/plugins/updaters cannot inject extra work. Retain and verify the ffmpeg helper's file-only protocols; run actual H.264/AAC, VP9/Opus, and AV1/Opus mux tests without network access for muxing.

**Approval prerequisite:** [`AGENTS.md`](../../AGENTS.md), Dependencies: “Ask before adding anything else.” PyInstaller and its build support packages would become new project-managed third-party build dependencies. No custom-runtime implementation, build-tool installation, or channel switch has been performed in this audit.

## Artifact authenticity and reproducibility

The existing source/archive hashes matched both cached artifacts and official release data:

| Artifact | SHA-256 |
| --- | --- |
| ffmpeg-9.0.1.tar.xz | `cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635` |
| yt-dlp_macos.zip, 2026.08.19 | `07e54b0865303c864006925913bce2604f8ee8cc6f18699bac9c309f9328a6d8` |

Detached upstream signatures were verified with GPG in an isolated temporary keyring, without modifying the developer's keyring:

- FFmpeg tarball: valid signature from `FCF986EA15E6E293A5644F10B4322F04D67658D8`, matching the key published on the [official download page](https://ffmpeg.org/download.html).
- yt-dlp `SHA2-256SUMS`: valid signature from `AC0CBBE6848D6A873464AF4E57CF65933B5A7581`, using the [key in the pinned release](https://github.com/yt-dlp/yt-dlp/blob/2026.08.19/public.key). The archive hash also matches GitHub's release asset digest.

The scripts still pin release versions and hashes. Ad-hoc code signatures created locally are distinct from upstream authenticity verification. Developer ID signing/notarization is not established by an ad-hoc development build.

## Implemented hardening

1. Fixed both scripts' documented empty-checksum inspection mode: an explicitly empty environment variable now prints the artifact hash and refuses installation. Previously `:-` silently substituted the trusted default, unexpectedly proceeding with a build/install.
2. Downloads now require HTTPS for both the initial URL and redirects, write into temporary files, and only publish a complete archive to the cache after curl succeeds. A failed transfer cannot become a persistent corrupt cache entry.
3. yt-dlp now prepares and verifies a separate staging tree before replacing the existing executable/runtime. Signing failures are fatal, incompatible native architectures are rejected, and the staged executable's reported version must match the pin.
4. ffmpeg now disables automatic detection of host-installed libraries and explicitly retains system zlib, bzip2, and iconv. It validates the completed binary's code signature, arm64 architecture, release version, and system-only dynamic linkage before replacing the current helper. Its final binary is published with a same-filesystem rename.
5. Build phases verify helper signatures and remove stale helpers when opt-in vendor files are absent, so an incremental build cannot accidentally retain an old enabled helper.
6. The core Swift package resolution is now tracked for reproducible checkouts.

The yt-dlp replacement still consists of separate executable/runtime moves after preparation; it is not a general concurrent-install or crash-atomic package manager. Run vendor scripts without a concurrent app build. ffmpeg source builds are reproducible in version and configuration, not guaranteed byte-for-byte identical across SDK/compiler versions.

## Executed checks

- Both fetch scripts passed `bash -n`.
- Both actual project build-phase scripts were run against a temporary source/app fixture; stale optional helpers were removed successfully when vendor inputs were absent.
- Empty and incorrect checksums were rejected by both scripts before installing anything.
- Injected interrupted curl downloads left neither completed cache files nor temporary download artifacts for either script.
- Injected yt-dlp codesign failure preserved the previous executable and runtime and removed staging files.
- Re-vendoring the official yt-dlp archive completed successfully; the helper launched and matched 2026.08.19.
- All **102 native `.so`/`.dylib` files**, the Python framework, and top-level executables passed strict code-signature verification. Nested linkage inspection found no unexpected non-system absolute library paths.
- A fresh ffmpeg source build completed. `otool -L` showed only `/usr/lib` and `/System/Library` dependencies. Its supported protocols are exactly `fd`, `file`, and `pipe` for input and output.
- The rebuilt vendor ffmpeg successfully muxed actual H.264/AAC, VP9/Opus, and AV1/Opus fixtures, generated locally. ffprobe confirmed both expected streams in all three Matroska outputs. The existing Swift mux tests prefer a Homebrew ffmpeg, so these extra direct vendor-binary checks were necessary.
- Fresh site install, complete dependency-tree validation, Astro checks, static build, and npm audit passed as described above.
- `git diff --check` passed for the changes.

No claim is made that this dependency audit proves all download/extraction paths or all production signatures. Engine regressions and full macOS visual verification are covered by the accompanying implementation audit.
