import SwiftUI
import DownloadModels

/// The detail pane: everything about the single selected download, including a live,
/// per-segment breakdown of which byte ranges are transferring.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let download = model.selectedDownload {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header(download)
                        Divider()
                        overview(download)
                        if !download.segments.isEmpty {
                            segments(download)
                        }
                        details(download)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
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

    private func header(_ download: Download) -> some View {
        HStack(spacing: 12) {
            Image(systemName: FileIcon.symbol(forFileName: download.fileName))
                .font(.largeTitle)
                .foregroundStyle(.primary)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(download.fileName)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Label(download.status.label, systemImage: download.status.systemImage)
                    .font(.subheadline)
                    .foregroundStyle(download.status.tint)
            }
        }
    }

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

            // Size / progress, in a clean baseline-aligned key–value grid.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 8) {
                statRow("Size", Format.bytes(download.totalBytes))
                statRow("Downloaded", Format.bytes(model.liveDownloadedBytes(download)))
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

    /// The peak/average transfer rates presented as two side-by-side stat tiles — a compact, scannable
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

    private func segments(_ download: Download) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Segments (\(download.segments.count))")
                .font(.subheadline.weight(.semibold))
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

    private func details(_ download: Download) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            detailRow("Source", value: download.url.absoluteString, mono: true)
            detailRow("Destination", value: download.destinationFilePath, mono: true)
            detailRow("Category", value: download.category.localizedName)
            detailRow("Resumable", value: download.supportsResume ? String(localized: "Yes (HTTP Range)") : String(localized: "No"))
            if let checksum = download.checksum {
                detailRow(
                    "\(checksum.algorithm.displayName) Checksum",
                    value: checksum.isUsable ? checksum.expectedHex : String(localized: "Not Available"),
                    mono: checksum.isUsable
                )
                if let verified = download.checksumVerified {
                    verificationRow(passed: verified)
                }
            }
            if let signature = download.signature {
                signatureRow(signature)
                if let authority = signature.authority {
                    detailRow("Signed by", value: authority)
                }
            }
            detailRow("Added", value: download.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let completed = download.completedAt {
                detailRow("Completed", value: completed.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private func detailRow(_ label: LocalizedStringKey, value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(mono ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        }
    }

    /// Checksum verification result, tinted for legibility — green for a pass, red (with a warning
    /// glyph) for a mismatch so a failed integrity check is unmistakable.
    private func verificationRow(passed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
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
        return VStack(alignment: .leading, spacing: 2) {
            Text("Signature")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label(label, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(color)
        }
    }
}
