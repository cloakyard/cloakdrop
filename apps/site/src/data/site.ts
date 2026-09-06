/** Shared, source-checked copy. Release notes remain the authority for shipped builds. */
export const site = {
  name: 'CloakDrop',
  url: 'https://drop.cloakyard.com',
  tagline: 'Open source. Down to the details.',
  description: 'A carefully made, open-source download manager for macOS. Parallel transfers, resumable downloads, video capture, and no app telemetry.',
  repo: 'https://github.com/cloakyard/cloakdrop',
  privacyPolicy: '/privacy/',
} as const;

export const downloads = {
  // GitHub excludes prereleases from /latest; the index also avoids stale asset names.
  href: `${site.repo}/releases`,
  sectionHref: '#download',
  label: 'Get the beta',
  actionLabel: 'Download from GitHub',
  status: 'Features shown reflect current source. Published betas may be a step behind; see the release notes.',
  note: 'Apple silicon · macOS 26 or later',
} as const;

export const nav = [
  { label: 'Product', href: '#product' },
  { label: 'Craft', href: '#provenance' },
  { label: 'Privacy', href: '#privacy' },
  { label: 'Download', href: '#download' },
] as const;

export const hero = {
  kicker: 'CloakDrop / Made for macOS',
  titleLead: 'Open source.',
  titleAccent: 'Down to the details.',
  lead: 'A carefully made download manager for people who expect more from open source. Native Mac controls, resilient transfers, and video capture. Free, and built in the open.',
  micro: 'MIT licensed · No account required',
  figLabel: 'THE REAL APP · A TRANSFER IN MOTION',
  shotAlt: 'CloakDrop on macOS showing an example Ubuntu ISO download, eight parallel ranges, live speed and progress, and a library of completed files.',
} as const;

export const product = {
  num: '01',
  label: 'Every download, considered',
  stories: [
    { id: 'transfer', n: '01', label: 'Resume', title: 'Pick up where you left off.',
      body: 'Parallel connections adapt to the file. Saved progress survives relaunch for supported downloads, with a single-stream fallback when a server refuses ranges.' },
    { id: 'capture', n: '02', label: 'Capture', title: 'Find the video. Keep your flow.',
      body: 'Paste a supported page or browse inside CloakDrop. Choose video quality, audio, and available subtitles; the native engine handles the download.' },
    { id: 'finish', n: '03', label: 'Finish', title: 'Care, through the last byte.',
      body: 'Check available checksums before an ordinary file reaches its destination. Keep an optional local receipt, while queues and routing rules keep the work organised.' },
  ],
} as const;

export const stats = [
  { value: 'Swift', label: 'native macOS interface', href: '#provenance' },
  { value: 'Local', label: 'saved progress', href: '#product' },
  { value: 'MIT', label: 'free & open source', href: site.repo },
  { value: '0', label: 'app telemetry', accent: true, href: '#privacy' },
] as const;
