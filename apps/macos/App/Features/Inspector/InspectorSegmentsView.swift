import SwiftUI
import DownloadModels

/// Technical progress stays available without displacing the selected file's source and destination.
/// The parent keys this view by download ID, so a new selection starts collapsed.
struct InspectorSegmentsView: View {
    @Environment(AppModel.self) private var model
    let download: Download
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            rows
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Design.cardFill, in: RoundedRectangle(cornerRadius: Design.cardRadius))
                .padding(.top, 8)
        } label: {
            Label("Segments (\(download.segments.count))", systemImage: "rectangle.split.3x1")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(download.segments.enumerated()), id: \.offset) { index, segment in
                let live = model.progress[download.id]?.value.segmentBytes[segment.id] ?? segment.downloadedBytes
                let fraction = segment.length > 0 ? min(1, Double(live) / Double(segment.length)) : 0
                HStack(spacing: 8) {
                    Text("#\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .leading)
                    CapsuleProgressBar(fraction: fraction, tint: download.status.tint)
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
}
