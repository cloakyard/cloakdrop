/**
 * Single source of truth for brand copy, links, and content.
 *
 * Copy is deliberately de-duplicated: each section owns one distinct message.
 *  - Hero      → the hook + what it does (speed, capture, resume)
 *  - Stats     → proof points at a glance
 *  - Features  → the individual capabilities
 *  - Privacy   → the egress story (the ONLY place privacy claims are spelled out)
 *  - Suite     → the Cloakyard family / shared design language
 */

export const site = {
  name: 'CloakDrop',
  domain: 'drop.cloakyard.com',
  url: 'https://drop.cloakyard.com',
  tagline: 'A fast, private, multi-segment download manager for macOS.',
  description:
    'CloakDrop is a native, sandboxed macOS download manager with IDM-class ' +
    'multi-segment speed, force-quit-proof resume, and zero telemetry — it ' +
    'feels like Apple made it.',
  repo: 'https://github.com/cloakyard/cloakdrop',
  releases: 'https://github.com/cloakyard/cloakdrop/releases/latest',
  suiteOrg: 'https://github.com/cloakyard',
  requirement: 'macOS Tahoe 26 · Apple silicon',
} as const;

/** Hero — the hook. Speed + capture + resume, no privacy claims (that's the band). */
export const hero = {
  lead:
    'Split any file into parallel segments for maximum speed, pull video and ' +
    'files straight off any web page, and pick up exactly where you left off ' +
    'after a crash or reboot.',
} as const;

export interface Stat {
  value: string;
  label: string;
}

export const stats: Stat[] = [
  { value: '8×', label: 'parallel segments' },
  { value: '1,800+', label: 'sites supported' },
  { value: 'Zero', label: 'telemetry' },
  { value: 'MIT', label: 'open source' },
];

export interface Feature {
  icon: string;
  title: string;
  body: string;
}

/** features[0] is rendered as the large bento cell. */
export const features: Feature[] = [
  {
    icon: 'bolt',
    title: 'Multi-segment speed',
    body: 'IDM-class downloading opens several connections per file and reassembles the pieces byte-perfect — so a single slow thread never caps your line.',
  },
  {
    icon: 'resume',
    title: 'Resume survives anything',
    body: 'Bytes stream into a sparse part file, so a force-quit, crash, or reboot picks up at the exact byte it left off — never from zero.',
  },
  {
    icon: 'globe',
    title: 'Browser & media grabs',
    body: 'A built-in WebKit browser surfaces the video, audio, and files on any page — HLS/DASH included — and takes over the download the moment one starts.',
  },
  {
    icon: 'sparkles',
    title: 'Truly native',
    body: 'A sandboxed SwiftUI app with Liquid Glass chrome and SF Symbols throughout. No Electron, no web views — every pixel belongs on macOS.',
  },
  {
    icon: 'tray',
    title: 'Capture from anywhere',
    body: 'A Share Extension, a “Send to CloakDrop” service, a clipboard watcher, Metalink multi-mirror, and checksum verification bring links in from all of macOS.',
  },
  {
    icon: 'clock',
    title: 'Queues, schedules & limits',
    body: 'Group downloads into queues, cap bandwidth on a schedule, and let big jobs run overnight — with per-queue concurrency you control.',
  },
];

/** Privacy band — the one place the egress story is told in full. */
export const privacy = {
  heading: 'The only thing that leaves your Mac is the file you asked for.',
  body:
    'CloakDrop has no servers of its own. Network activity is limited to the URLs ' +
    'you choose to download and the sites you open in the built-in browser. No ' +
    'browsing history is kept, and a one-click wipe clears cookies and site data ' +
    'whenever you want.',
  points: ['No telemetry', 'No analytics', 'No accounts', 'No history', 'No phone-home'],
} as const;

export interface SuiteApp {
  name: string;
  blurb: string;
  href: string;
  self?: boolean;
}

export const suite: SuiteApp[] = [
  { name: 'CloakDrop', blurb: 'Download manager', href: site.repo, self: true },
  { name: 'CloakPDF', blurb: 'PDF toolkit', href: 'https://github.com/cloakyard' },
  { name: 'CloakIMG', blurb: 'Image toolkit', href: 'https://github.com/cloakyard' },
  { name: 'CloakResume', blurb: 'Résumé builder', href: 'https://github.com/cloakyard' },
];
