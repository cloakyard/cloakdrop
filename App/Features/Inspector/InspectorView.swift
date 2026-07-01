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
        VStack(alignment: .leading, spacing: 10) {
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
            LabeledContent("Size", value: Format.bytes(download.totalBytes))
            LabeledContent("Downloaded", value: Format.bytes(model.liveDownloadedBytes(download)))
            if download.status == .downloading {
                LabeledContent("Time Left", value: Format.eta(model.eta(download)))
            }
        }
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
