import SwiftUI
import DownloadModels

/// The detail pane: everything about the single selected download. The layout adapts to the
/// download's *type* — a plain HTTP/FTP file, a multi-segment transfer, a Metalink multi-source
/// grab, or an HLS/DASH media grab all get a header + at-a-glance chips, then only the sections
/// that apply (Media, Segments, Details, Integrity, Provenance).
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let download = model.selectedDownload {
                content(download)
            } else {
                EmptyStateView("No Selection", systemImage: "info.circle") {
                    Text("Select a download to see its details.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // A stable, full-bleed container so toggling the inspector or changing the selection
        // doesn't shift the layout.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(_ download: Download) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(download)
                chips(download)
                overview(download)
                if download.segments.count > 1 {
                    segments(download)
                }
                if let plan = download.mediaPlan {
                    mediaSection(plan)
                }
                detailsSection(download)
                if download.checksum != nil || download.signature != nil {
                    integritySection(download)
                }
                if let provenance = download.provenance {
                    provenanceSection(provenance)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: Header

    private func header(_ download: Download) -> some View {
        HStack(spacing: 13) {
            Image(systemName: headerSymbol(download))
                .font(.system(size: 33))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(download.isMedia ? Color.accentColor : Color.primary)
                .frame(width: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(download.fileName)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                statusPill(download.status)
            }
            Spacer(minLength: 0)
        }
    }

    /// A type-aware glyph: media, FTP, and Metalink downloads read at a glance; everything else
    /// falls back to the by-extension file icon.
    private func headerSymbol(_ download: Download) -> String {
        if download.isMedia { return "film" }
        if let scheme = download.url.scheme?.lowercased(), scheme.hasPrefix("ftp") { return "server.rack" }
        if let mirrors = download.mirrors, !mirrors.isEmpty { return "square.stack.3d.up" }
        return FileIcon.symbol(forFileName: download.fileName)
    }

    /// The status as a tinted capsule — more legible than a bare label, and consistent with the
    /// list rows.
    private func statusPill(_ status: DownloadStatus) -> some View {
        Label(status.label, systemImage: status.systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(status.tint.opacity(0.14), in: Capsule())
    }

    // MARK: At-a-glance chips

    /// A wrapping row of small facts tuned to the download's type — transport, connection count,
    /// media format/quality, mirror count — so what *kind* of download this is reads instantly.
    private func chips(_ download: Download) -> some View {
        FlowLayout(spacing: 6) {
            if let scheme = download.url.scheme?.uppercased() {
                chip(Text(verbatim: scheme), "network")
            }
            if let plan = download.mediaPlan {
                chip(Text(verbatim: plan.format.rawValue.uppercased()), "film")
                if let resolution = plan.resolution {
                    chip(Text(verbatim: "\(resolution.qualityHeight)p"), "4k.tv")
                }
            } else if download.segments.count > 1 {
                chip(Text("\(download.segments.count) connections"), "cable.connector")
            }
            if let mirrors = download.mirrors, !mirrors.isEmpty {
                chip(Text("\(download.transferSources.count) sources"), "square.stack.3d.up")
            }
        }
    }

    private func chip(_ text: Text, _ symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).imageScale(.small)
            text
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    // MARK: Overview

    private func overview(_ download: Download) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let fraction = model.liveFraction(download), download.status != .completed {
                ProgressView(value: fraction) {
                    HStack {
                        Text(Format.percent(fraction))
                        Spacer()
                        Text(Format.speed(model.liveSpeed(download)))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .tint(download.status.tint)
            }

            // Size / progress, in a clean baseline-aligned key–value grid — media grabs count
            // segments (their byte total usually isn't known up front), files count bytes.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 8) {
                if let plan = download.mediaPlan {
                    statRow("Segments", "\(download.mediaCompletedSegments) / \(plan.totalSegments)")
                    if download.downloadedBytes > 0 {
                        statRow("Downloaded", Format.bytes(download.downloadedBytes))
                    }
                } else {
                    statRow("Size", Format.bytes(download.totalBytes))
                    statRow("Downloaded", Format.bytes(model.liveDownloadedBytes(download)))
                }
                if download.status == .downloading {
                    statRow("Time Left", Format.eta(model.eta(download)))
                }
            }

            // Per-download speed summary — live while transferring, the final figures once done.
            let peak = model.peakSpeed(download)
            let average = model.averageSpeed(download)
            if peak > 0 || average > 0 {
                speedStats(peak: peak, average: average)
            }
        }
    }

    /// One `label — value` line in the overview grid: a secondary label and a monospaced value that
    /// lines up in a column with its neighbours.
    private func statRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().gridColumnAlignment(.leading)
        }
    }

    /// The peak/average transfer rates as two side-by-side stat tiles — a compact, scannable
    /// summary of how the download performed.
    private func speedStats(peak: Double, average: Double) -> some View {
        HStack(spacing: 10) {
            if peak > 0 { speedTile("Peak Speed", value: peak, symbol: "gauge.high") }
            if average > 0 { speedTile("Average Speed", value: average, symbol: "gauge.medium") }
        }
    }

    private func speedTile(_ label: LocalizedStringKey, value: Double, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(Format.speed(value))
                .font(.title3.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Segments (multi-connection transfers)

    private func segments(_ download: Download) -> some View {
        section("Segments (\(download.segments.count))", "rectangle.split.3x1") {
            ForEach(download.segments) { segment in
                let live = model.progress[download.id]?.segmentBytes[segment.id] ?? segment.downloadedBytes
                let fraction = segment.length > 0 ? min(1, Double(live) / Double(segment.length)) : 0
                HStack(spacing: 8) {
                    Text("#\(segment.id + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .leading)
                    ProgressView(value: fraction)
                        .tint(download.status.tint)
                    Text(Format.bytes(segment.length))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
                // One VoiceOver stop per segment ("#1, 45%, 2 MB") instead of three.
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Media (HLS/DASH grabs)

    private func mediaSection(_ plan: MediaPlan) -> some View {
        section("Media", "film") {
            kvRow("Format", plan.format.rawValue.uppercased())
            if let resolution = plan.resolution {
                kvRow("Resolution", "\(resolution.width) × \(resolution.height)")
            }
            kvRow("Audio", plan.hasSeparateAudio
                  ? String(localized: "Separate track, muxed")
                  : String(localized: "Included"))
            if let subtitles = plan.subtitles, !subtitles.isEmpty {
                kvRow("Subtitles", "\(subtitles.count)")
            }
            if plan.duration > 0 {
                kvRow("Duration", Format.eta(plan.duration))
            }
        }
    }

    // MARK: Details

    private func detailsSection(_ download: Download) -> some View {
        section("Details", "info.circle") {
            longRow("Source", download.url.absoluteString)
            longRow("Destination", download.destinationFilePath)
            kvRow("Category", download.category.localizedName)
            kvRow("Resumable", download.supportsResume
                  ? String(localized: "Yes (HTTP Range)")
                  : String(localized: "No"))
            kvRow("Added", download.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let completed = download.completedAt {
                kvRow("Completed", completed.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    // MARK: Integrity (checksum + signature)

    private func integritySection(_ download: Download) -> some View {
        section("Integrity", "checkmark.shield") {
            if let checksum = download.checksum {
                longRow(
                    "\(checksum.algorithm.displayName) Checksum",
                    checksum.isUsable ? checksum.expectedHex : String(localized: "Not Available"),
                    mono: checksum.isUsable
                )
                if let verified = download.checksumVerified {
                    verificationRow(passed: verified)
                }
            }
            if let signature = download.signature {
                signatureRow(signature)
                if let authority = signature.authority {
                    kvRow("Signed by", authority)
                }
            }
        }
    }

    /// The verified-download provenance record — CloakDrop's signature feature. Shows the one trust
    /// verdict, the SHA-256, and a button to save the full receipt.
    private func provenanceSection(_ provenance: ProvenanceReceipt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Provenance", systemImage: trustSymbol(provenance.trustLevel))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.saveProvenanceReceipt(provenance)
                } label: {
                    Label("Save Receipt…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: trustSymbol(provenance.trustLevel))
                        .foregroundStyle(trustColor(provenance.trustLevel))
                        .symbolRenderingMode(.hierarchical)
                    Text(trustLabel(provenance.trustLevel))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(trustColor(provenance.trustLevel))
                }
                kvRow("Transport", provenance.transportSecure
                      ? String(localized: "Encrypted (TLS)") : String(localized: "Cleartext"))
                if !provenance.mirrors.isEmpty {
                    kvRow("Mirrors", String(provenance.mirrors.count))
                }
                if let sha256 = provenance.sha256 {
                    longRow("SHA-256", sha256)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: Reusable section + rows

    /// A titled card: a small secondary header (icon + title) above a rounded container holding the
    /// section's rows. Replaces bare dividers with clear, scannable grouping.
    private func section(
        _ title: LocalizedStringKey,
        _ symbol: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    /// A compact `label   value` row for short values.
    private func kvRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value)
                .font(.caption)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    /// A stacked `label` above a full-width, selectable value — for long values (URLs, paths,
    /// hashes) that shouldn't be crammed into a trailing column.
    private func longRow(_ label: LocalizedStringKey, _ value: String, mono: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(mono ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Trust presentation

    private func trustSymbol(_ level: TrustLevel) -> String {
        switch level {
        case .verified: return "checkmark.seal.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private func trustColor(_ level: TrustLevel) -> Color {
        switch level {
        case .verified: return .green
        case .warning: return .red
        case .unknown: return .secondary
        }
    }

    private func trustLabel(_ level: TrustLevel) -> LocalizedStringKey {
        switch level {
        case .verified: return "Verified"
        case .warning: return "Warning"
        case .unknown: return "Unverified"
        }
    }

    /// Checksum verification result, tinted for legibility — green for a pass, red (with a warning
    /// glyph) for a mismatch so a failed integrity check is unmistakable.
    private func verificationRow(passed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Verification")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label(
                passed ? "Passed" : "Failed",
                systemImage: passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(passed ? Color.green : Color.red)
        }
    }

    /// Code-signature assessment for an installable download — green & sealed when signed and valid,
    /// red when the signature failed to validate, neutral when the file carries none.
    private func signatureRow(_ signature: SignatureAssessment) -> some View {
        let label: LocalizedStringKey
        let symbol: String
        let color: Color
        switch signature.status {
        case .valid:
            label = "Signed & valid"; symbol = "checkmark.seal.fill"; color = .green
        case .invalid:
            label = "Invalid signature"; symbol = "exclamationmark.triangle.fill"; color = .red
        case .unsigned:
            label = "Unsigned"; symbol = "seal"; color = .secondary
        }
        return VStack(alignment: .leading, spacing: 3) {
            Text("Signature")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label(label, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(color)
        }
    }
}

/// A left-to-right wrapping layout for the inspector's metadata chips (SwiftUI ships no flow
/// layout). Lays each subview at its ideal size, wrapping to a new row when the current one is full.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.width, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                       anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
