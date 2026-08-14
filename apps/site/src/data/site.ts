/**
 * Shared product copy and structured content for the CloakDrop brand site.
 * Components read the reusable claims and links here while keeping their own
 * interface labels and visual-example annotations alongside the markup they describe.
 *
 * The site is an editorial, magazine-style layout: numbered sections, a mono kicker
 * on each, big Archivo display headlines, and hairline dividers throughout.
 * Copy is deliberately de-duplicated — each section owns one distinct message.
 *
 * Product claims are verified against the macOS app source. Keep this file in sync
 * with the engine and Settings UI rather than promoting illustrative UI values.
 */

export const site = {
  name: 'CloakDrop',
  url: 'https://drop.cloakyard.com',
  tagline: 'A native, private, multi-segment download manager for macOS.',
  description:
    'CloakDrop is a native, sandboxed macOS download manager with adaptive ' +
    'multi-segment transfers, relaunch-safe resume, integrated video ' +
    'capture, and no app telemetry.',
  repo: 'https://github.com/cloakyard/cloakdrop',
  privacyPolicy: '/privacy/',
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
  status: 'This page documents the current source; published beta builds may lag behind it.',
  note: 'Apple silicon · macOS 26 or later',
} as const;

export const nav = [
  { label: 'Product', href: '#product' },
  { label: 'Receipt', href: '#provenance' },
  { label: 'Privacy', href: '#privacy' },
  { label: 'Download', href: '#download' },
] as const;

/* Hero — the hook. Keep it to the product promise; proof and privacy live below. */
export const hero = {
  kicker: 'Native macOS · Open source',
  titleLead: 'Built to resume.',
  titleAccent: 'Finished with a record.',
  lead:
    'Plan parallel ranges automatically or choose the connection count. CloakDrop ' +
    'restores saved progress after relaunch and verifies available checksums locally ' +
    'before the finished file appears.',
  micro: 'MIT licensed · No account required',
  figLabel: 'NATIVE APP PREVIEW · ADAPTIVE RANGE TRANSFER',
  shotAlt:
    'The CloakDrop app window showing an Ubuntu ISO transfer planned across eight ' +
    'ranges for this example, with live speed, ETA, and per-range progress above ' +
    'a library of completed downloads.',
} as const;

export const product = {
  num: '01',
  label: 'The transfer',
  stories: [
    {
      id: 'transfer',
      n: '01',
      label: 'Transfer',
      title: 'Adaptive ranges. One unbroken file.',
      body:
        'Eligible files split across validated parallel byte ranges. Automatic mode ' +
        'sizes the plan up to your ceiling, or you can choose the connection count. ' +
        'Compatible saved offsets restore after relaunch.',
    },
    {
      id: 'capture',
      n: '02',
      label: 'Capture',
      title: 'Every way in, one native engine.',
      body:
        'Paste a URL, drag a link, share from another app, or use the built-in ' +
        'browser. Video formats and ordinary files land in the same engine.',
    },
    {
      id: 'finish',
      n: '03',
      label: 'Finish',
      title: 'Route the work, then get out of the way.',
      body:
        'The Main Queue, routing rules, duplicate detection, speed profiles, and guarded ' +
        'post-processing take care of the work after a link is added.',
    },
  ],
} as const;

/* Spec strip — four proof points under the hero. */
export const stats = [
  { value: '1–32', label: 'maximum setting range', href: '#product' },
  { value: '4', label: 'HTTP · HTTPS · FTP · FTPS', href: '#product' },
  {
    value: 'Local',
    label: 'verification & receipts',
    href: '#provenance',
  },
  { value: '0', label: 'app telemetry endpoints', accent: true, href: '#privacy' },
] as const;

/* 02 — Provenance receipt (the dark, signature section). */
export const provenance = {
  num: '02',
  label: 'Local verification',
  title: 'A local record of what arrived.',
  bodyHtml:
    'When checksum verification is enabled (the default), a supplied or same-origin ' +
    'discovered checksum is tested against private staging ' +
    'bytes before the final file is exposed. When receipt generation is enabled, a completed ' +
    'ordinary file download can then generate an exportable ' +
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
  ],
  verdict: { label: 'TRUST', value: '✓ VERIFIED' },
} as const;

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
      body: 'Choose system, direct, or manual HTTP, HTTPS, or SOCKS5 routing for HTTP-based downloads and speed tests. Manual routing is mirrored into the built-in browser.',
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
  ],
} as const;

/* 04 — Privacy. The one place the egress story is told in full. */
export const privacy = {
  num: '04',
  label: 'The network boundary',
  title: 'No telemetry. A defined network boundary.',
  body:
    'CloakDrop has no accounts, analytics, telemetry, automatic crash uploads, or ' +
    'update pings. Network activity is limited to transfers and features you start ' +
    'or configure. App state stays in local storage, browser data stays in WebKit, and ' +
    'remembered site and proxy credentials use Keychain. Credentials attached to a ' +
    'download can also remain in its local record so that transfer can resume.',
  points: ['Telemetry endpoints', 'Accounts', 'Automatic crash uploads', 'Update pings'],
} as const;

/* Engineering note shown beside the download CTA. */
export const hood = {
  title: 'A native core with a thin interface.',
  body:
    'The interface stays thin because the download engine is a separate, headless ' +
    'Swift package. The same tested core owns transfers, persistence, and recovery.',
  specs: [
    { k: 'LANGUAGE', v: 'Swift 6, strict concurrency' },
    { k: 'UI', v: 'SwiftUI · Liquid Glass' },
    { k: 'ENGINE', v: 'Actor-based, one actor per transfer' },
    { k: 'STORAGE', v: 'Local SQLite · Keychain for remembered credentials' },
  ],
} as const;

export const suiteApps = [
  { name: 'CloakPDF', href: 'https://pdf.cloakyard.com' },
  { name: 'CloakIMG', href: 'https://img.cloakyard.com' },
  { name: 'CloakResume', href: 'https://resume.cloakyard.com' },
] as const;
