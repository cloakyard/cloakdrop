import SwiftUI

/// Settings ▸ Privacy: CloakDrop's full privacy policy, adapted for a native download manager
/// from the Cloakyard suite's shared policy. The page scrolls; the summary card up top is the
/// at-a-glance version, the sections below are the detail.
struct PrivacySettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                summaryCard
                Divider()
                policySections
                footer
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 38))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Privacy Policy")
                        .font(.title2.weight(.bold))
                    Text("Last updated \(Self.revisionDate.formatted(.dateTime.month(.wide).day().year()))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Text("""
            CloakDrop is a free, open-source download manager that runs entirely on your Mac. This \
            policy explains what personal data we collect (spoiler: none) and exactly which network \
            connections the app makes.
            """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Summary card (at a glance)

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Private by design")
                .font(.subheadline.weight(.semibold))
            guarantee("Everything runs on-device")
            guarantee("No accounts, analytics, or telemetry")
            guarantee("No connections you didn't choose")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func guarantee(_ text: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Text(text)
            Spacer(minLength: 0)
        }
    }

    // MARK: Detailed sections

    private var policySections: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("Your downloads stay on your Mac", """
            Every part of what CloakDrop does — multi-segment downloading, pause and resume, \
            checksum verification, code-signature checks, archive extraction, and media muxing — \
            runs locally on your Mac. The files you download, your download history, and the \
            addresses you fetch are never sent to us or to anyone else.
            """)

            bulletedSection(
                "The only connections CloakDrop makes",
                intro: """
                A download manager has to reach the internet, so CloakDrop is precise about when it \
                does. It connects only to:
                """,
                bullets: [
                    "The download links you choose — and any redirects or mirrors they point to.",
                    "A proxy server, and only if you configure one in Network settings.",
                    "A speed-test provider (Cloudflare or Ookla), and only while a test you started is running."
                ],
                outro: """
                That is the complete list. There are no update pings, no analytics beacons, and no \
                phone-home of any kind.
                """
            )

            bulletedSection(
                "No personal data collected",
                intro: "CloakDrop does not collect, store, or transmit any personal information, including:",
                bullets: [
                    "Names, email addresses, or account details — there are no accounts.",
                    "IP addresses or device identifiers.",
                    "Usage analytics or behavioural tracking.",
                    "Crash reports or diagnostic data."
                ],
                outro: nil
            )

            section("Where your data lives", """
            Your download list and preferences are kept in a local database inside the app's \
            sandbox. Passwords for websites, FTP servers, and proxies are stored in the macOS \
            Keychain. CloakDrop runs fully sandboxed — it can reach only your Downloads folder and \
            the destinations you explicitly pick (remembered as security-scoped bookmarks), never \
            the rest of your disk. Everything stays on your Mac and can be deleted at any time; \
            removing the app leaves nothing behind but the files you saved.
            """)

            section("Bundled tools", """
            CloakDrop includes two open-source command-line tools: ffmpeg, to combine separate \
            video and audio into one playable file, and yt-dlp, to read the list of formats a \
            video page offers. Both run locally as sandboxed helpers and only read or transform \
            data already on your Mac. CloakDrop's own engine performs every byte of downloading — \
            neither tool opens a network connection of its own.
            """)

            section("Browser extensions", """
            The optional Safari, Chrome, and Firefox extensions detect downloadable media on the \
            page you are viewing and pass it to CloakDrop. When you pick a download, the extension \
            reads the cookies scoped to that one address — so files behind a login download \
            correctly — and forwards them a single time to the app on your Mac. Those cookies are \
            never stored by the extension and never sent anywhere else.
            """)

            section("Open source and licensing", """
            CloakDrop is open source under the MIT License. You can read the entire source code, \
            verify every claim in this policy for yourself, and build your own copy — with no fees \
            and no restrictions.
            """)

            section("Your rights, and changes to this policy", """
            Because CloakDrop collects no personal data, there is nothing for us to disclose, \
            correct, or delete on your behalf under GDPR, CCPA, or similar laws. If this policy \
            ever changes, the updated version will appear here with a new date above; given \
            CloakDrop's privacy-by-design nature, significant changes are unlikely.
            """)
        }
    }

    private func section(_ heading: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(heading)
                .font(.headline)
            Text(body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bulletedSection(
        _ heading: LocalizedStringKey,
        intro: LocalizedStringKey,
        bullets: [LocalizedStringKey],
        outro: LocalizedStringKey?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading)
                .font(.headline)
            Text(intro)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(bullets.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 4))
                            .foregroundStyle(.tertiary)
                        Text(bullets[index])
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.leading, 2)
            if let outro {
                Text(outro)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            linkRow("View the source on GitHub", url: AppLinks.repository)
            linkRow("Ask a question or report an issue", url: AppLinks.reportBug)
        }
    }

    private func linkRow(_ label: LocalizedStringKey, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.forward.square")
                    .foregroundStyle(.tint)
                Text(label)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .font(.callout)
    }

    /// The policy's revision date, rendered per-locale. Fixed (not "today") so it reflects when
    /// the text last changed.
    private static let revisionDate: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 8
        return Calendar.current.date(from: components) ?? Date()
    }()
}
