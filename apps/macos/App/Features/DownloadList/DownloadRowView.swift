import SwiftUI
import DownloadModels

/// One download in the content list: type icon, name, live progress, and a status detail
/// line. Rows are deliberately plain (no glass) per the Liquid Glass guidance — glass is for
/// chrome, content stays legible.
struct DownloadRowView: View {
    @Environment(AppModel.self) private var model
    /// SwiftUI raises this for emphasized selection on some list styles — honor it when present.
    @Environment(\.backgroundProminence) private var backgroundProminence
    /// The list container's focus-derived emphasis signal (see `selectionEmphasis`) — the reliable
    /// one for `.inset` lists on macOS, where `backgroundProminence` stays `.standard`.
    @Environment(\.selectionEmphasis) private var selectionEmphasis
    let download: Download

    private var fraction: Double? { model.liveFraction(download) }
    private var isSelected: Bool { model.selectedDownloadIDs.contains(download.id) }
    /// White-content styling applies only on the accent-colored *emphasized* highlight. Selection
    /// alone isn't enough: an unfocused list draws the gray unemphasized highlight, where forced
    /// white washes out — and without this check, tinted content on the accent highlight would
    /// paint accent-on-accent (an active download's bar and pause button would disappear).
    private var onAccent: Bool {
        isSelected && (backgroundProminence == .increased || selectionEmphasis)
    }

    /// A compact quality/format badge for a media grab — "1080p", "2160p", "HLS", … `nil` for file
    /// downloads. Labels by the streaming convention (`qualityHeight`), so a portrait/Shorts grab
    /// reads "1080p" (not "1920p") and a cinematic 2:1 grab reads "2160p", matching YouTube.
    private var mediaBadge: String? {
        guard let plan = download.mediaPlan else { return nil }
        if let resolution = plan.resolution { return "\(resolution.qualityHeight)p" }
        return plan.format == .hls ? "HLS" : "DASH"
    }

    /// An at-a-glance integrity seal for a finished download: green when a checksum matched or the
    /// code signature is valid, red when either failed. Nothing to show otherwise. Semantic colors
    /// are kept even on the selection highlight — a warning must always read as a warning.
    @ViewBuilder
    private var trustBadge: some View {
        switch download.trustLevel {
        case .verified:
            Image(systemName: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityLabel(Text("Verified"))
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityLabel(Text("Integrity warning"))
        case .unknown:
            EmptyView()
        }
    }

    var body: some View {
        // The leading icon and trailing action align to a shared row midline. Normally that's
        // the row's vertical center; while downloading, the progress bar overrides it to its own
        // center so the disc icon lines up exactly with the bar — not with the text block.
        HStack(alignment: .rowMidline, spacing: 12) {
            leadingIcon
                .frame(width: 40, height: 40)
                // Decorative: the file name below already conveys the row's identity to VoiceOver.
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(download.fileName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    trustBadge
                    if let badge = mediaBadge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(onAccent ? Color.white : Color.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(onAccent ? AnyShapeStyle(Color.white.opacity(0.25)) : AnyShapeStyle(.quaternary), in: Capsule())
                    }
                }

                if showsProgressBar {
                    progressBar
                        .alignmentGuide(.rowMidline) { $0[VerticalAlignment.center] }
                }

                statusSubtitle
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // Fill the row so the trailing action always sits at the right edge, regardless of
            // how short the title/status text is — otherwise the button floats in next to the
            // text and rows look ragged.
            .frame(maxWidth: .infinity, alignment: .leading)
            // Read as one VoiceOver stop — "name, badge, status detail" — instead of three; the
            // quick-action button stays a separate, labeled element.
            .accessibilityElement(children: .combine)

            quickAction
        }
        .padding(.vertical, 6)
        // Lazily render a poster thumbnail for a completed video grab when the row appears (covers
        // relaunch, where the grab finished in a past session). Fresh completions trigger via the model.
        .task(id: download.id) { model.ensureThumbnail(for: download) }
    }

    /// A poster thumbnail for a completed video grab, or the SF-Symbol file glyph otherwise.
    @ViewBuilder
    private var leadingIcon: some View {
        if let thumbnail = model.thumbnailURL(for: download) {
            MediaThumbnailImage(url: thumbnail)
        } else {
            Image(systemName: FileIcon.symbol(forFileName: download.fileName))
                // Larger than the trailing action so the file is clearly the row's subject —
                // a leading identity icon sized for this three-line row, per Apple's list metrics.
                .font(.system(size: 30, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                // Monochrome and legible: primary normally, white on the emphasized highlight.
                .foregroundStyle(onAccent ? Color.white : Color.primary)
        }
    }

    /// Only active transfers carry a progress bar. Completed / failed / queued / scheduled rows
    /// stay compact — the status line sits directly under the title, with no reserved gap.
    private var showsProgressBar: Bool {
        download.status == .downloading || download.status == .paused
    }

    @ViewBuilder
    private var progressBar: some View {
        if download.status == .downloading, fraction == nil {
            // Unknown total size — indeterminate.
            ProgressView()
                .progressViewStyle(.linear)
                .controlSize(.small)
                .frame(height: 4)
        } else {
            // On the emphasized highlight the bar goes white so it stays visible on the accent; the
            // activity sweep then flips to a translucent dark band (a white sweep would vanish on
            // the white fill).
            CapsuleProgressBar(
                fraction: fraction ?? 0,
                tint: onAccent ? .white : download.status.tint,
                track: onAccent ? AnyShapeStyle(Color.white.opacity(0.3)) : AnyShapeStyle(.quaternary),
                isActive: download.status == .downloading,
                sweep: onAccent ? .black.opacity(0.22) : .white.opacity(0.35)
            )
        }
    }

    @ViewBuilder
    private var quickAction: some View {
        // On the emphasized selection highlight, force white so the control stays visible.
        switch download.status {
        case .downloading, .queued:
            CircleActionButton(symbol: "pause.fill", tint: onAccent ? .white : .accentColor, help: "Pause") {
                model.pause(download.id)
            }
        case .paused:
            CircleActionButton(symbol: "play.fill", tint: onAccent ? .white : .accentColor, help: "Resume") {
                model.resume(download.id)
            }
        case .failed:
            CircleActionButton(symbol: "arrow.clockwise", tint: onAccent ? .white : .orange, help: "Retry") {
                model.resume(download.id)
            }
        case .completed:
            CircleActionButton(symbol: "folder", tint: onAccent ? .white : .green, help: "Reveal in Finder") {
                model.revealInFinder(download)
            }
        default:
            EmptyView()
        }
    }

    /// The status line plus the checksum result. "Verified" reads plainly; a "Checksum mismatch"
    /// is tinted red so a failed integrity check stands out in the list. On the emphasized accent
    /// highlight the red would sit at poor contrast, so the text goes white there — the row's red
    /// trust triangle still carries the warning.
    private var statusSubtitle: Text {
        let base = Text(detailLine)
        guard download.status == .completed else { return base }
        if download.checksumVerified == true {
            return base + Text(verbatim: " · ") + Text("Verified")
        }
        if download.checksumVerified == false {
            let mismatch = Text("Checksum mismatch")
            return base + Text(verbatim: " · ") + (onAccent ? mismatch.foregroundStyle(.white) : mismatch.foregroundStyle(.red))
        }
        return base
    }

    private var detailLine: String {
        switch download.status {
        case .downloading:
            // A media grab shows its segment count only until the engine learns the byte total
            // (immediately for a paired video+audio grab) — then the byte/ETA line takes over,
            // which moves smoothly even when the whole video is a single segment.
            if let segments = model.liveMediaSegments(download), model.liveTotalBytes(download) == nil {
                let speed = Format.speed(model.liveSpeed(download))
                return String(localized: "\(segments.completed) of \(segments.total) segments · \(speed)")
            }
            let done = Format.bytes(model.liveDownloadedBytes(download))
            let total = Format.bytes(model.liveTotalBytes(download))
            let speed = Format.speed(model.liveSpeed(download))
            let eta = Format.eta(model.eta(download))
            return String(localized: "\(done) of \(total) · \(speed) · \(eta) left")
        case .completed:
            // The checksum result is appended — and, for a mismatch, colored — in `statusSubtitle`.
            return String(localized: "\(Format.bytes(download.totalBytes)) · Completed")
        case .failed(let reason):
            return reason
        case .paused:
            if let segments = model.liveMediaSegments(download) {
                return String(localized: "Paused · \(segments.completed) of \(segments.total) segments")
            }
            let done = Format.bytes(model.liveDownloadedBytes(download))
            let total = Format.bytes(download.totalBytes)
            return String(localized: "Paused · \(done) of \(total)")
        case .queued:
            return String(localized: "Queued")
        case .scheduled:
            return String(localized: "Scheduled")
        case .canceled:
            return String(localized: "Canceled")
        }
    }
}

/// A cached poster thumbnail rendered to fill the 40×40 icon slot (center-cropped, rounded). Loads
/// the small JPEG once when it appears; a subtle fill backs it while loading or as letterbox.
private struct MediaThumbnailImage: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        RoundedRectangle(cornerRadius: Design.inlineRadius, style: .continuous)
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "film")
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Design.inlineRadius, style: .continuous))
            .task(id: url) {
                // Read off the main actor — a synchronous disk read per appearing row stacks into
                // visible hitches when fast-scrolling a media-heavy list.
                let data = await Task.detached { try? Data(contentsOf: url) }.value
                image = data.flatMap(NSImage.init(data:))
            }
    }
}

private extension VerticalAlignment {
    /// A row-wide midline shared by the icon, progress bar, and quick action. Defaults to the
    /// view's vertical center; the progress bar overrides it to its own center during a transfer.
    enum RowMidlineID: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }

    static let rowMidline = VerticalAlignment(RowMidlineID.self)
}
