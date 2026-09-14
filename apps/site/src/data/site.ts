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
  label: 'Download CloakDrop',
  actionLabel: 'Download from GitHub',
  status: 'Version 1.0.0 is in release preparation. Find available builds, checksums, and release notes on GitHub.',
  note: 'Apple silicon · macOS 26 or later',
} as const;

export const nav = [
  { label: 'Product', href: '#product' },
  { label: 'Craft', href: '#provenance' },
  { label: 'Privacy', href: '#privacy' },
  { label: 'Download', href: '#download' },
] as const;

export const hero = {
  kicker: 'CloakDrop / Built for macOS 27',
  titleLead: 'Open source.',
  titleAccent: 'Down to the details.',
  lead: 'Parallel downloads, saved progress, and video capture in a native Mac app. Keep transfers organised, check the finished file, and get on with your day. Free, and built in the open.',
  micro: 'MIT licensed · No account required',
  figLabel: 'INSIDE CLOAKDROP',
  shotAlt: 'CloakDrop on macOS showing an example Ubuntu ISO download, eight parallel ranges, live speed and progress, and a library of completed files.',
} as const;

export const product = {
  num: '01',
  label: 'Every download, considered',
  features: [
    { label: 'Download & resume', title: 'Pick up where you left off.',
      body: 'Connections adapt to the file. Pause a transfer, close the app, and continue from saved progress when the server supports resume.',
      detail: 'Queues, schedules, and speed limits keep larger jobs under control.' },
    { label: 'Video & audio', title: 'Keep what you came for.',
      body: 'Browse inside CloakDrop or paste a supported page. Choose video quality, audio, and available subtitles, then let the app handle the transfer.',
      detail: 'Direct media, HLS, and DASH. Availability depends on the site; DRM media is excluded.' },
    { label: 'Integrity & files', title: 'Finish with confidence.',
      body: 'Verify an available checksum before an ordinary file is saved. Keep a local receipt and leave existing files intact.',
      detail: 'Categories and routing rules put completed downloads where they belong.' },
  ],
} as const;

export const stats = [
  { value: 'Swift', label: 'native macOS interface', href: '#provenance' },
  { value: 'Local', label: 'saved progress', href: '#product' },
  { value: 'MIT', label: 'free & open source', href: site.repo },
  { value: '0', label: 'app telemetry', accent: true, href: '#privacy' },
] as const;
