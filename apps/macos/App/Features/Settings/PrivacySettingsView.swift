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
            guarantee("Only connections you initiate or configure")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.cardFill, in: RoundedRectangle(cornerRadius: Design.cardRadius))
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
            runs locally on your Mac. CloakDrop does not upload your files, download history, or \
            addresses to the CloakDrop project for analytics, profiling, or telemetry. Requests \
            still go to the services you choose, as described below.
            """)

            bulletedSection(
                "The only connections CloakDrop makes",
                intro: """
                A download manager has to reach the internet, so CloakDrop is precise about when it \
                does. It connects only to:
                """,
                bullets: [
                    // swiftlint:disable:next line_length
                    "Download work you configure — URLs, redirects, mirrors, retries, schedules, repeating transfers, and automatic resumes.",
                    "Same-origin checksum files (.sha256, .sha1, or .md5), when automatic checksum verification and discovery are enabled.",
                    "A video page and related service endpoints, when yt-dlp resolves formats for a page you submit.",
                    // swiftlint:disable:next line_length
                    "Pages and subresources loaded by the built-in browser — plus your query to the selected search engine, if address-bar search is on, only when you press Return.",
                    // swiftlint:disable:next line_length
                    "Proxy routing for HTTP-based downloads and speed tests — the macOS system proxy by default, a manual proxy when selected, or Direct mode. FTP and FTPS stay direct; a selected manual proxy is also mirrored into the built-in browser.",
                    "A speed-test provider (Cloudflare or Ookla), and only while a test you started is running.",
                    // swiftlint:disable:next line_length
                    "The ad blocker's open-source blocklist, if you pick one in Browser settings — fetched only when you choose it or press Update Now, never on its own."
                ],
                outro: """
                That is the complete list. There are no update pings, no analytics beacons, and no \
                phone-home of any kind.
                """
            )

            bulletedSection(
                "No personal data collected",
                intro: "The CloakDrop project has no accounts or analytics service and receives none of the following from the app:",
                bullets: [
                    "Names, email addresses, or account details — there are no accounts.",
                    "IP addresses or device identifiers.",
                    "Usage analytics or behavioural tracking.",
                    "Crash reports or diagnostic data."
                ],
                outro: nil
            )

            section("Where your data lives", """
            Your download list, preferences, URLs, request data, per-download HTTP or FTP \
            credentials, checksums, and receipts can be kept in the app's local sandbox database. \
            Website credentials you choose to remember and manual-proxy secrets are stored in the \
            macOS Keychain; an individual download credential can also be in its database record so \
            the transfer can resume. Browser cookies and site data stay in WebKit's local store. \
            CloakDrop can reach only its containers, your Downloads folder, and destinations you \
            explicitly pick. Removing the app does not necessarily remove saved files outside its \
            container or Keychain items; you can manage those items in macOS Keychain Access.
            """)

            section("Bundled tools", """
            CloakDrop includes two open-source, sandboxed command-line helpers. ffmpeg works locally \
            to combine or transform media. yt-dlp may contact a video page you submit and related \
            service endpoints to resolve metadata and formats, but it does not download the \
            selected media payload. CloakDrop's own engine transfers the files and media you select.
            """)

            section("The built-in browser", """
            CloakDrop has a browser built in: open it, visit any site, and grab the video, audio, \
            or files on the page. WebKit loads the pages you visit and the resources they request, \
            which can include third-party content; the optional blocker can reduce some requests. \
            CloakDrop keeps no browsing-history list — only cookies and site data, so you stay \
            signed in between launches — and one button in Browser settings wipes all of it. When \
            you grab a file, cookies applicable to that address ride along so downloads behind a \
            login work. If you turn address-bar search off, address-bar text is never sent to a \
            search engine.
            """)

            section("What contacted services can see", """
            Servers and proxies you choose to contact can receive ordinary request information, \
            including your IP address, the requested URL or resource, and applicable headers, \
            cookies, or credentials. The CloakDrop project does not receive or retain a separate \
            copy of that information.
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
        components.month = 8
        components.day = 9
        return Calendar.current.date(from: components) ?? Date()
    }()
}
