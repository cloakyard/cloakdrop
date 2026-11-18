/** Shared, source-checked copy. Release notes remain the authority for shipped builds. */
export const site = {
  name: 'CloakDrop',
  url: 'https://drop.cloakyard.com',
  tagline: 'Your downloads. Under control.',
  description: 'A carefully made, open-source download manager for macOS. Parallel transfers, resumable downloads, video capture, and no app telemetry.',
  repo: 'https://github.com/cloakyard/cloakdrop',
  privacyPolicy: '/privacy/',
} as const;

export const downloads = {
  // GitHub excludes release candidates from /latest. Link the verified RC explicitly.
  href: `${site.repo}/releases/tag/v1.0.0-rc.4`,
  sectionHref: '#download',
  label: 'Download CloakDrop',
  actionLabel: 'Download RC 4',
  status: 'Version 1.0.0 RC 4, build 20261118.6. Check for signed updates in Settings → About. The installer, checksums and release notes are on GitHub.',
  note: 'Apple silicon · macOS 26 or later',
} as const;

export const nav = [
  { label: 'Product', href: '#product' },
  { label: 'Craft', href: '#provenance' },
  { label: 'Privacy', href: '#privacy' },
  { label: 'Download', href: '#download' },
] as const;

export const hero = {
  titleLead: 'Your downloads.',
  titleAccent: 'Under control.',
  lead: 'Parallel downloads, saved progress, and video capture in a native Mac app. Keep things organised and get on with your day.',
  micro: 'MIT licensed · No account required',
  shotAlt: 'CloakDrop on macOS with an Ubuntu ISO download selected, its speed and progress in the inspector, and five completed files in the queue.',
} as const;

export const product = {
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
