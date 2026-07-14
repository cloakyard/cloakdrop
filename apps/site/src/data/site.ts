/**
 * Single source of truth for the CloakDrop brand site — every string, link, and
 * content row lives here; components stay presentational and read from this file.
 *
 * The site is an editorial, magazine-style layout: numbered sections (01–07), a mono
 * kicker on each, big Archivo display headlines, and hairline dividers throughout.
 * Copy is deliberately de-duplicated — each section owns one distinct message.
 *
 * Facts verified against the app on 2026-07-13: 11 localizations and 471 tests / 72
 * suites in DownloaderCore. Keep them in sync if the app changes.
 */

export const site = {
  name: 'CloakDrop',
  domain: 'drop.cloakyard.com',
  url: 'https://drop.cloakyard.com',
  tagline: 'A fast, private, multi-segment download manager for macOS.',
  description:
    'CloakDrop is a native, sandboxed macOS download manager with IDM-class ' +
    'multi-segment speed, force-quit-proof resume, video from ~1,800 sites, and ' +
    'zero telemetry — it behaves like part of macOS.',
  repo: 'https://github.com/cloakyard/cloakdrop',
  suiteOrg: 'https://github.com/cloakyard',
  requirement: 'macOS 27 Golden Gate · Apple silicon',
} as const;

/**
 * Download CTA. Points at the Releases *index*, not a versioned asset: the link then never
 * needs touching as builds come and go, and there's no exact-filename coupling to break — an
 * asset URL 404s the moment an upload is named differently.
 *
 * /releases rather than /releases/latest on purpose: GitHub excludes pre-releases from
 * "latest", so while the beta is the only release, /releases/latest would 404.
 */
export const downloads = {
  href: 'https://github.com/cloakyard/cloakdrop/releases',
  label: 'Download the beta',
  /** Shown next to the CTA — the betas are not notarized yet, so say so up front. */
  note: 'Beta · Apple silicon · unnotarized — right-click ▸ Open on first launch',
} as const;

export interface NavLink {
  label: string;
  href: string;
}

export const nav: NavLink[] = [
  { label: 'Features', href: '#engine' },
  { label: 'Privacy', href: '#privacy' },
  { label: 'Under the hood', href: '#hood' },
  { label: 'Suite', href: '#suite' },
];

/* Hero — the hook. Speed + capture + resume + privacy, in one breath. */
export const hero = {
  kicker: 'macOS 27 Golden Gate · Swift 6 · No Electron',
  titleLead: 'A download\nmanager that\nbehaves like',
  titleAccent: 'part of\nmacOS.',
  lead:
    'Serious multi-segment speed over HTTP, HTTPS and FTP. Video from ~1,800 ' +
    'sites. Resume that survives a reboot. And nothing ever phones home.',
  micro: 'Free & open source · MIT · No account, ever',
  figLabel: 'FIG.01 — CLOAKDROP.APP',
  shotAlt:
    'The CloakDrop app window downloading an Ubuntu 26.04 ISO across 8 parallel ' +
    'segments, with live speed, ETA, and a per-segment progress inspector, above ' +
    'a library of five completed downloads.',
} as const;

export interface Stat {
  value: string;
  label: string;
  accent?: boolean;
  /**
   * Optional count-up target. `value` stays the source of truth for what renders
   * server-side (and with JS off); these only tell motion.ts how to re-derive it
   * frame by frame, so `countTo` + affixes must format back to exactly `value`.
   * Omit to leave a stat static — "0 bytes phoned home" counts up from nothing
   * to nothing, so animating it is just a flicker.
   */
  countTo?: number;
  countPrefix?: string;
  countSuffix?: string;
  countComma?: boolean;
}

/* Spec strip — four proof points under the hero. */
export const stats: Stat[] = [
  { value: '8×', label: 'parallel segments', countTo: 8, countSuffix: '×' },
  {
    value: '~1,800',
    label: 'video sites recognized',
    countTo: 1800,
    countPrefix: '~',
    countComma: true,
  },
  { value: '471', label: 'tests · 72 suites', countTo: 471 },
  { value: '0', label: 'bytes phoned home', accent: true },
];

export interface NumberedFeature {
  n: string;
  title: string;
  body: string;
}

/* 01 — The engine. Two lead cards + a four-up grid. */
export const engine = {
  num: '01',
  label: 'The engine',
  title: 'Everything a download deserves.',
  lead:
    'One actor-based engine handles HTTP, HTTPS and FTP alike — segmenting, ' +
    'resuming, and verifying every transfer the same way.',
  /**
   * Decorative segment fills for the multi-segment card's mini-inspector.
   * Deliberately unordered: real segments race independently, so a sorted
   * staircase would misrepresent how a transfer actually looks mid-flight.
   */
  segBars: ['68%', '100%', '84%', '41%', '77%', '58%', '91%', '63%'],
  lead1: {
    n: '01',
    title: 'Multi-segment speed',
    body:
      'Each file splits into parallel streams over HTTP Range and reassembles ' +
      "byte-perfectly — with automatic single-stream fallback when a server can't " +
      'do ranges. FTP and FTPS segment the same way, natively.',
  } as NumberedFeature,
  lead2: {
    n: '02',
    title: 'Resume survives anything',
    body:
      'True byte-range resume outlives an app relaunch and a reboot — it never ' +
      're-downloads a byte. When the network drops, per-segment retry with ' +
      'exponential backoff and jitter pauses and picks up on its own.',
  } as NumberedFeature,
  grid: [
    {
      n: '03',
      title: 'Bandwidth control',
      body:
        'Global and per-download speed caps — a GCRA throttle that holds the ' +
        'aggregate honestly under many connections — plus time-of-day profiles.',
    },
    {
      n: '04',
      title: 'Queues, rules & sorting',
      body:
        'Per-queue concurrency, a rule-based routing engine to folders and ' +
        'queues, duplicate detection, and auto-sorting of finished files.',
    },
    {
      n: '05',
      title: 'Multi-source mirrors',
      body:
        'Open a Metalink and segments spread across mirrors, failing over the ' +
        'moment one dies or serves corrupt bytes — then verify.',
    },
    {
      n: '06',
      title: 'Post-processing',
      body:
        'Native ZIP auto-extraction — Zip-Slip and bomb guarded — a Gatekeeper ' +
        'quarantine flag, plus notify, quit, or run a Shortcut.',
    },
  ] as NumberedFeature[],
} as const;

export interface ReceiptRow {
  k: string;
  v: string;
}

/* 02 — Provenance receipt (the dark, signature section). */
export const provenance = {
  num: '02',
  label: 'Only in CloakDrop',
  title: 'Every download leaves a receipt.',
  bodyHtml:
    'Each completed download earns a local, exportable ' +
    '<strong>Provenance Receipt</strong> — sources, TLS details, whole-file ' +
    'SHA-256, and checksum + code-signature verdicts in one trust record. ' +
    'Checksums verify automatically from a hash you supply or an auto-discovered ' +
    'sibling <code>.sha256</code>; <code>.app</code> and <code>.dmg</code> files ' +
    'get a notarization check on top. No other download manager produces one.',
  receipt: [
    { k: 'FILE', v: 'ubuntu-26.04.iso' },
    { k: 'SIZE', v: '6.52 GB' },
    { k: 'SOURCE', v: 'releases.ubuntu.com' },
    { k: 'TLS', v: 'TLS 1.3 ✓' },
    { k: 'SHA-256', v: 'a1b4…9f2e ✓ MATCH' },
    { k: 'SIGNATURE', v: 'NOTARIZED ✓' },
  ] as ReceiptRow[],
  verdict: { label: 'VERDICT', value: '✓ TRUSTED' },
} as const;

/* 03 — Capture. Three ways in. */
export const capture = {
  num: '03',
  label: 'Capture',
  title: 'If you can see it, you can grab it.',
  lead:
    'Paste, drag, share, or browse — every road leads into the same segmented ' +
    'engine, and your logins come along.',
  items: [
    {
      n: '01',
      title: 'A browser that grabs',
      body:
        'A built-in WebKit browser (⇧⌘B) lists the video, audio, and files on any ' +
        'page — ads and beacons filtered out — and takes over downloads IDM-style ' +
        'the moment a page starts one. An optional ad & tracker blocker is a switch away.',
    },
    {
      n: '02',
      title: '~1,800 video sites',
      body:
        'Paste a YouTube link — or any site yt-dlp can read — and CloakDrop ' +
        'resolves the formats and downloads with its own segmented engine. yt-dlp ' +
        'only reads and deciphers; it never downloads a byte.',
    },
    {
      n: '03',
      title: 'From anywhere',
      body:
        'Clipboard watching, drag & drop, a link-grabber that pattern-expands ' +
        'file[01-50].zip, a scheduler, a Share Extension, and a “Send to ' +
        'CloakDrop” Services item.',
    },
  ] as NumberedFeature[],
} as const;

export interface DetailItem {
  icon: string;
  title: string;
  body: string;
}

/* 04 — The details. A six-cell grid of the small stuff. */
export const details = {
  num: '04',
  label: 'The details',
  title: 'Small things, done right.',
  lead: 'The parts you only notice because they never get in your way.',
  items: [
    {
      icon: 'shield',
      title: 'Integrity & trust',
      body: 'MD5 / SHA-1 / SHA-256 verified on completion, from your hash or a discovered sibling checksum.',
    },
    {
      icon: 'film',
      title: 'Media grabbing',
      body: 'HLS and DASH streams, AES-128 decrypt, audio paired and muxed into a clean, playable file — no re-encode.',
    },
    {
      icon: 'gauge',
      title: 'Built-in speed test',
      body: 'Speedometer dials for download, upload, latency, and jitter. Cloudflare or Ookla, strictly manual.',
    },
    {
      icon: 'bars',
      title: 'Download stats',
      body: 'Private lifetime totals with a playful monthly tier badge — Warming Up all the way to ISP’s Worst Nightmare.',
    },
    {
      icon: 'globe',
      title: 'Fully localized',
      body: 'Every UI string translated into 11 languages, from English and Spanish to Japanese, Arabic, and Hindi.',
    },
    {
      icon: 'menubar',
      title: 'Menu bar & Dock',
      body: 'A live menu-bar extra and a Dock icon that shows overall progress at a glance, without opening the window.',
    },
  ] as DetailItem[],
} as const;

/* 05 — Privacy. The one place the egress story is told in full. */
export const privacy = {
  num: '05',
  label: 'Privacy is the whole point',
  title: 'The only requests it makes are the ones you start.',
  body:
    'No accounts, no analytics, no crash reporting. The built-in browser keeps ' +
    'your logins but records no history, with a one-click wipe of all site data. ' +
    'Downloads and settings live in a local SQLite database you can export or ' +
    'delete — and the App Sandbox means CloakDrop only ever touches the folders ' +
    'you point it at.',
  points: ['No telemetry', 'No analytics', 'No accounts', 'No crash reporting', 'No phone-home'],
} as const;

/* 06 — Under the hood. The spec sheet. */
export const hood = {
  num: '06',
  label: 'Under the hood',
  title: 'Native to the bone.',
  body:
    'No Electron, no web views, no third-party Swift dependencies beyond GRDB. ' +
    'Full light and dark, VoiceOver and full-keyboard access, a live menu-bar ' +
    'extra, a Dock icon that shows progress — and every string translated into ' +
    '11 languages.',
  specs: [
    { k: 'LANGUAGE', v: 'Swift 6, strict concurrency' },
    { k: 'UI', v: 'SwiftUI · Liquid Glass' },
    { k: 'ENGINE', v: 'Actor-based, one actor per transfer' },
    { k: 'NETWORKING', v: 'URLSession + native FTP/FTPS' },
    { k: 'PERSISTENCE', v: 'GRDB (SQLite) · Keychain creds' },
    { k: 'DEPENDENCIES', v: 'None beyond GRDB' },
  ] as ReceiptRow[],
} as const;

export interface SuiteApp {
  name: string;
  desc: string;
  tag: string;
  /** Omitted for the current app (CloakDrop) — that row is not a link. */
  href?: string;
  self?: boolean;
}

/* 07 — The Cloakyard suite. */
export const suite = {
  num: '07',
  label: 'Part of Cloakyard',
  title: 'One suite. One set of principles.',
  lead:
    'Apps that are private by default — on the web and on the Mac — each built ' +
    'with the same attention to design, and each doing one job well.',
  org: 'github.com/cloakyard',
  apps: [
    { name: 'CloakDrop', desc: 'Multi-segment download manager', tag: 'THIS APP', self: true },
    { name: 'CloakPDF', desc: 'Private PDF toolkit', tag: 'CLOAKYARD', href: 'https://pdf.cloakyard.com' },
    { name: 'CloakIMG', desc: 'Image conversion & editing', tag: 'CLOAKYARD', href: 'https://img.cloakyard.com' },
    { name: 'CloakResume', desc: 'Résumé builder', tag: 'CLOAKYARD', href: 'https://resume.cloakyard.com' },
  ] as SuiteApp[],
} as const;
