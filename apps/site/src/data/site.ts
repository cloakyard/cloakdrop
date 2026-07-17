/**
 * Single source of truth for the CloakDrop brand site — every string, link, and
 * content row lives here; components stay presentational and read from this file.
 *
 * The site is an editorial, magazine-style layout: numbered sections (01–07), a mono
 * kicker on each, big Archivo display headlines, and hairline dividers throughout.
 * Copy is deliberately de-duplicated — each section owns one distinct message.
 *
 * Product claims are verified against the macOS app source. Keep this file in sync
 * with the engine and Settings UI rather than promoting illustrative UI values.
 */

export const site = {
  name: 'CloakDrop',
  domain: 'drop.cloakyard.com',
  url: 'https://drop.cloakyard.com',
  tagline: 'A fast, private, multi-segment download manager for macOS.',
  description:
    'CloakDrop is a native, sandboxed macOS download manager with IDM-class ' +
    'adaptive multi-segment transfers, relaunch-safe resume, integrated video ' +
    'capture, and zero telemetry — it behaves like part of macOS.',
  repo: 'https://github.com/cloakyard/cloakdrop',
  privacyPolicy: '/privacy/',
  suiteOrg: 'https://github.com/cloakyard',
  requirement: 'macOS 26 or later · Apple silicon',
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
  sectionHref: '#download',
  label: 'Get the beta',
  actionLabel: 'Open GitHub Releases',
  status: 'CloakDrop is in active development.',
  note: 'Apple silicon · macOS 26 or later',
} as const;

export interface NavLink {
  label: string;
  href: string;
}

export const nav: NavLink[] = [
  { label: 'Product', href: '#product' },
  { label: 'Receipt', href: '#provenance' },
  { label: 'Privacy', href: '#privacy' },
  { label: 'Download', href: '#download' },
];

/* Hero — the hook. Keep it to the product promise; proof and privacy live below. */
export const hero = {
  kicker: 'Native macOS · Open source',
  titleLead: 'Built to resume.',
  titleAccent: 'Finished with proof.',
  lead:
    'A native transfer engine that adapts parallel ranges to the file and source, ' +
    'recovers saved progress after relaunch, and verifies the result locally.',
  micro: 'MIT licensed · No account, ever',
  figLabel: 'LIVE APP · ADAPTIVE RANGE TRANSFER',
  shotAlt:
    'The CloakDrop app window showing an Ubuntu ISO transfer planned across eight ' +
    'ranges for this example, with live speed, ETA, and per-range progress above ' +
    'a library of completed downloads.',
} as const;

export interface ProductStory {
  n: string;
  label: string;
  title: string;
  body: string;
  points: readonly string[];
  visual: 'speed' | 'capture' | 'organize';
}

export const product = {
  num: '01',
  label: 'The transfer',
  title: 'From link to finished file, without the busywork.',
  lead:
    'Three focused stages cover the whole job. Each one stays quiet until it has ' +
    'something useful to do.',
  stories: [
    {
      n: '01',
      label: 'Transfer',
      title: 'Adaptive lanes. Saved-offset recovery.',
      body:
        'Eligible files split across a configurable number of byte ranges. The plan ' +
        'adapts to file size and range support, then restores saved offsets after relaunch.',
      points: ['Configurable range plan', 'Single-stream fallback', 'Relaunch-safe resume'],
      visual: 'speed',
    },
    {
      n: '02',
      label: 'Capture',
      title: 'Bring links in from anywhere.',
      body:
        'Paste a URL, drag a link, share from another app, or use the built-in ' +
        'browser. Video formats and ordinary files land in the same engine.',
      points: ['Built-in WebKit browser', 'Bundled video resolver', 'Clipboard, drag & Share'],
      visual: 'capture',
    },
    {
      n: '03',
      label: 'Finish',
      title: 'Let the finish take care of itself.',
      body:
        'The Main Queue, routing rules, duplicate detection, speed profiles, and guarded ' +
        'post-processing take care of the work after a link is added.',
      points: ['First-match routing rules', 'Aggregate bandwidth caps', 'Guarded ZIP extraction'],
      visual: 'organize',
    },
  ] as readonly ProductStory[],
} as const;

export interface Stat {
  value: string;
  label: string;
  accent?: boolean;
  /**
   * Optional count-up target. `value` stays the source of truth for what renders
   * server-side (and with JS off); these only tell motion.ts how to re-derive it
   * frame by frame, so `countTo` + affixes must format back to exactly `value`.
   * Omit to leave a stat static — a zero-value telemetry fact should not flicker.
   */
  countTo?: number;
  countPrefix?: string;
  countSuffix?: string;
  countComma?: boolean;
  href?: string;
}

/* Spec strip — four proof points under the hero. */
export const stats: Stat[] = [
  { value: '1–32', label: 'maximum setting range', href: '#product' },
  {
    value: '4',
    label: 'HTTP · HTTPS · FTP · FTPS',
    countTo: 4,
    href: '#product',
  },
  {
    value: 'Local',
    label: 'verification & receipts',
    href: '#provenance',
  },
  { value: '0', label: 'telemetry endpoints', accent: true, href: '#privacy' },
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
    'resuming supported ranges, and keeping transfer state local.',
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
    title: 'Resume from saved offsets',
    body:
      'Saved byte-range progress survives an app relaunch and reboot. When the ' +
      'remote object and local part data still match, each range continues from ' +
      'its recorded offset.',
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
  label: 'Local verification',
  title: 'A local record of what arrived.',
  bodyHtml:
    'When enabled, a completed file download can generate an exportable ' +
    '<strong>Provenance Receipt</strong> — source, transport security, whole-file ' +
    'SHA-256, and any available checksum or code-signature result. Checksum ' +
    'discovery stays same-origin; <code>.app</code> and <code>.dmg</code> files ' +
    'can also receive an offline signature assessment.',
  receipt: [
    { k: 'FILE', v: 'CloakDrop-1.0.dmg' },
    { k: 'SIZE', v: '44,875,776 bytes' },
    { k: 'SOURCE', v: 'github.com/cloakyard' },
    { k: 'TRANSPORT', v: 'ENCRYPTED (TLS)' },
    { k: 'SHA-256', v: 'a1b4…9f2e' },
    { k: 'SIGNATURE', v: 'VALID' },
  ] as ReceiptRow[],
  verdict: { label: 'TRUST', value: '✓ VERIFIED' },
} as const;

/* 03 — Capture. Three ways in. */
export const capture = {
  num: '03',
  label: 'Capture',
  title: 'Bring a link in the way that fits.',
  lead:
    'Paste, drag, share, or browse. Browser-originated grabs can carry the ' +
    'cookies and referrer needed for signed-in downloads.',
  items: [
    {
      n: '01',
      title: 'A browser that grabs',
      body:
        'A built-in WebKit browser (⇧⌘B) surfaces grabbable media and files as they ' +
        'appear. Explicit downloads and attachments can hand off to CloakDrop; an ' +
        'optional ad and tracker blocker is available separately.',
    },
    {
      n: '02',
      title: 'Video pages, resolved locally',
      body:
        'Submit a supported video-page URL and the bundled yt-dlp helper resolves ' +
        'metadata and media URLs. It does not transfer the selected media payload; ' +
        "CloakDrop's engine does.",
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
  meta: readonly string[];
}

/* 03 — Native details. Compact polish that belongs nowhere else on the page. */
export const details = {
  num: '03',
  label: 'Native control deck',
  title: 'Serious tools, already inside.',
  lead: 'Routing, diagnosis, local statistics, and ambient controls—without a companion utility or account.',
  items: [
    {
      icon: 'network',
      title: 'Proxy routing',
      body: 'Route HTTP-based traffic through the macOS system proxy, connect directly, or configure a manual HTTP, HTTPS, or SOCKS5 endpoint.',
      meta: ['System', 'Direct', 'Manual'],
    },
    {
      icon: 'gauge',
      title: 'Built-in speed test',
      body: 'Run Cloudflare or Ookla only when you choose. Measure download, upload, idle and loaded latency, and jitter.',
      meta: ['Download', 'Upload', 'Latency'],
    },
    {
      icon: 'bars',
      title: 'Local download stats',
      body: 'See today, this month, and all-time totals with a monthly rank. Everything is resettable and stored on this Mac.',
      meta: ['Today', 'Month', 'All time'],
    },
    {
      icon: 'menubar',
      title: 'Menu bar & Dock',
      body: 'See aggregate speed and progress, inspect active work, and pause or resume without bringing the main window forward.',
      meta: ['Live speed', 'Progress', 'Controls'],
    },
  ] as DetailItem[],
} as const;

/* 05 — Privacy. The one place the egress story is told in full. */
export const privacy = {
  num: '04',
  label: 'The network boundary',
  title: 'No telemetry. A defined network boundary.',
  body:
    'CloakDrop has no accounts, analytics, telemetry, automatic crash uploads, or ' +
    'update pings. Network activity is limited to transfers and features you start ' +
    'or configure. App state stays in local storage, browser data stays in WebKit, ' +
    'and remembered secrets use Keychain.',
  points: ['Telemetry endpoints', 'Accounts', 'Automatic crash uploads', 'Update pings'],
} as const;

/* 06 — Under the hood. The spec sheet. */
export const hood = {
  num: '06',
  label: 'Under the hood',
  title: 'A native core, kept deliberately small.',
  body:
    'The interface stays thin because the download engine is a separate, headless ' +
    'Swift package. The same tested core owns transfers, persistence, and recovery.',
  specs: [
    { k: 'LANGUAGE', v: 'Swift 6, strict concurrency' },
    { k: 'UI', v: 'SwiftUI · Liquid Glass' },
    { k: 'ENGINE', v: 'Actor-based, one actor per transfer' },
    { k: 'STORAGE', v: 'Local SQLite · Keychain credentials' },
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
