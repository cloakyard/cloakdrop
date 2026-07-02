import SwiftUI
import DownloadModels

/// Quality picker for an adaptive-streaming (HLS/DASH) grab. Shown after a manifest URL resolves,
/// it lists the available renditions (highest quality first) and lets the user pick one before the
/// grab is enqueued. Audio/subtitle renditions are surfaced as a note; the chosen video variant is
/// what's downloaded (separate-track muxing lands with the remux work in 4c).
struct MediaPickerSheet: View {
    @Environment(AppModel.self) private var model
    let selection: MediaSelection
    @State private var chosenVariantID: String = ""

    private var variants: [MediaVariant] {
        selection.stream.variants.sorted { $0.bandwidth > $1.bandwidth }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            List(selection: $chosenVariantID) {
                ForEach(variants) { variant in
                    variantRow(variant).tag(variant.id)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 200)

            Divider()
            footer
        }
        .frame(width: 440, height: 460)
        .onAppear {
            chosenVariantID = selection.stream.bestVariant?.id ?? variants.first?.id ?? ""
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 26))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Choose Quality")
                    .font(.headline)
                Text(selection.request.url.host() ?? selection.request.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(selection.stream.format == .hls ? "HLS" : "DASH")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
        }
        .padding(16)
    }

    private func variantRow(_ variant: MediaVariant) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(qualityLabel(variant))
                    .fontWeight(.medium)
                if let resolution = variant.resolution {
                    Text("\(resolution.width)×\(resolution.height)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(bitrate(variant.bandwidth))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if trackNote != nil {
                Label(trackNote!, systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelMediaSelection() }
                    .keyboardShortcut(.cancelAction)
                Button("Download") { model.confirmMediaSelection(variantID: chosenVariantID) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(chosenVariantID.isEmpty)
            }
        }
        .padding(16)
    }

    /// A concise quality label — "1080p", "2160p", … by the streaming convention (so portrait/Shorts
    /// read "1080p" not "1920p", and a cinematic 2:1 master reads "2160p" as YouTube labels it);
    /// otherwise "Audio" for an audio-only rendition or "Video" for a video rendition that omits
    /// `RESOLUTION` (some HLS masters do, while still declaring a video codec — not "Audio").
    private func qualityLabel(_ variant: MediaVariant) -> String {
        if let resolution = variant.resolution { return "\(resolution.qualityHeight)p" }
        return variant.isAudioOnly ? String(localized: "Audio") : String(localized: "Video")
    }

    private func bitrate(_ bandwidth: Int) -> String {
        guard bandwidth > 0 else { return "" }
        if bandwidth >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bandwidth) / 1_000_000)
        }
        return "\(bandwidth / 1000) kbps"
    }

    private var trackNote: LocalizedStringKey? {
        let audio = selection.stream.audioTracks.count
        let subtitle = selection.stream.subtitleTracks.count
        guard audio > 0 || subtitle > 0 else { return nil }
        return "\(audio) audio · \(subtitle) subtitle tracks available"
    }
}
