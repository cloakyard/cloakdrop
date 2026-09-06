import SwiftUI
import DownloadModels

/// Quality picker for an adaptive-streaming (HLS/DASH) grab. Shown after a manifest URL resolves,
/// it lists available renditions (highest quality first), audio languages, and subtitle sidecars.
struct MediaPickerSheet: View {
    @Environment(AppModel.self) private var model
    let selection: MediaSelection
    @State private var chosenVariantID: String = ""
    @State private var selectedSubtitleIDs: Set<String> = []
    @State private var selectedAudioTrackID: String = ""
    @State private var audioOnly = false

    private var variants: [MediaVariant] {
        let sorted = selection.stream.variants.sorted(by: MediaVariant.higherQualityFirst)
        let video = sorted.filter { !$0.isAudioOnly }
        return canGrabAudioOnly && !video.isEmpty ? video : sorted
    }

    private var subtitleTracks: [MediaTrack] {
        selection.stream.subtitleTracks
    }

    private var audioTracks: [MediaTrack] {
        audioOnly ? selection.stream.standaloneAudioTracks : selection.stream.audioTracks
    }

    /// Whether an "audio only" grab is offered (the stream has a separate audio track to extract).
    private var canGrabAudioOnly: Bool { selection.stream.hasGrabbableAudio }

    /// Whether to offer an audio-language choice (the stream carries more than one audio track).
    private var canChooseAudio: Bool { audioTracks.count >= 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if canGrabAudioOnly {
                modePicker
            }

            Group {
                if audioOnly {
                    VStack(spacing: 10) {
                        Image(systemName: "waveform")
                            .font(.system(size: 36, weight: .regular))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Downloads the sound only, saved as an audio file.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $chosenVariantID) {
                        ForEach(variants) { variant in
                            variantRow(variant).tag(variant.id)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minHeight: 200)

            Divider()
            footer
        }
        .frame(width: 440, height: 460)
        .onAppear {
            chosenVariantID = selection.stream.bestVariant?.id ?? variants.first?.id ?? ""
            selectedAudioTrackID = selection.stream.defaultAudioTrack?.id ?? ""
            // Default the subtitle selection to the user's "Download subtitles" preference.
            if model.grabSubtitlesEnabled, let track = subtitleTracks.first(where: \.isDefault) ?? subtitleTracks.first {
                selectedSubtitleIDs = [track.id]
            }
        }
        .onChange(of: audioOnly) { _, _ in
            if !audioTracks.contains(where: { $0.id == selectedAudioTrackID }) {
                selectedAudioTrackID = audioTracks.first(where: \.isDefault)?.id ?? audioTracks.first?.id ?? ""
            }
        }
    }

    /// The shared sheet chrome, with the host as subtitle and the stream format as the accessory.
    private var header: some View {
        SheetHeader(
            title: audioOnly ? "Download Audio" : "Choose Quality",
            systemImage: "play.rectangle.on.rectangle",
            subtitle: Text(selection.request.url.host() ?? selection.request.url.absoluteString)
        ) {
            Group {
                if selection.extracted != nil {
                    Text("Video")
                } else {
                    Text(verbatim: selection.stream.format == .hls ? "HLS" : "DASH")
                }
            }
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
        }
    }

    /// Video vs. audio-only. Only shown when the stream exposes a separate audio track to extract.
    private var modePicker: some View {
        Picker("", selection: $audioOnly) {
            Text("Video").tag(false)
            Text("Audio only").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Download format")
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
        VStack(alignment: .leading, spacing: 8) {
            if canChooseAudio {
                audioPicker
            }
            if !subtitleTracks.isEmpty {
                subtitlePicker
            } else if !canChooseAudio, trackNote != nil {
                Label(trackNote!, systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelMediaSelection() }
                    .keyboardShortcut(.cancelAction)
                Button("Download") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!audioOnly && chosenVariantID.isEmpty)
            }
            .padding(.top, 2)
        }
        .padding(16)
    }

    private func confirm() {
        // In audio-only mode the primary id names the audio track to grab (fall back to the default);
        // in video mode it names the chosen resolution, with the audio choice passed alongside.
        let defaultAudio = audioOnly ? selection.stream.defaultStandaloneAudioTrack : selection.stream.defaultAudioTrack
        let audioTrackID = selectedAudioTrackID.isEmpty ? (defaultAudio?.id ?? "") : selectedAudioTrackID
        model.confirmMediaSelection(
            variantID: audioOnly ? audioTrackID : chosenVariantID,
            subtitleTrackIDs: Array(selectedSubtitleIDs),
            audioOnly: audioOnly,
            audioTrackID: canChooseAudio ? audioTrackID : nil
        )
    }

    /// A single-select menu of audio languages, shown when the stream carries more than one audio
    /// track. In video mode it picks which audio to mux in; in audio-only mode, which one to extract.
    private var audioPicker: some View {
        HStack(spacing: 8) {
            Label("Audio", systemImage: "waveform")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(audioTracks) { track in
                    subtitleMenuItem(title: audioLabel(track), isOn: selectedAudioTrackID == track.id) {
                        selectedAudioTrackID = track.id
                    }
                }
            } label: {
                Text(audioTracks.first { $0.id == selectedAudioTrackID }.map(audioLabel) ?? String(localized: "Default"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 280, alignment: .trailing)
        }
    }

    /// A human label for an audio track: a localized language name ("en" → "English"), else the
    /// manifest's own name (or container, for a page grab), else a generic "Audio".
    private func audioLabel(_ track: MediaTrack) -> String {
        if let code = track.language, let localized = Locale.current.localizedString(forLanguageCode: code) {
            let matches = audioTracks.filter {
                $0.language.flatMap { Locale.current.localizedString(forLanguageCode: $0) } == localized
            }
            if matches.count > 1, let name = track.name, !name.isEmpty,
               name.caseInsensitiveCompare(localized) != .orderedSame {
                return localized + " · " + name
            }
            return localized
        }
        if let name = track.name, !name.isEmpty { return name }
        return String(localized: "Audio")
    }

    /// A compact multi-select menu of the available subtitle languages, saved as `.srt` sidecars.
    private var subtitlePicker: some View {
        HStack(spacing: 8) {
            Label("Subtitles", systemImage: "captions.bubble")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                subtitleMenuItem(title: String(localized: "None"), isOn: selectedSubtitleIDs.isEmpty) {
                    selectedSubtitleIDs.removeAll()
                }
                Divider()
                ForEach(subtitleTracks) { track in
                    subtitleMenuItem(title: subtitleLabel(track), isOn: selectedSubtitleIDs.contains(track.id)) {
                        toggleSubtitle(track.id)
                    }
                }
                if subtitleTracks.count > 1 {
                    Divider()
                    Button("Select All") { selectedSubtitleIDs = Set(subtitleTracks.map(\.id)) }
                }
            } label: {
                Text(subtitleSummary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    /// A menu row that shows a leading checkmark only when selected (an empty SF Symbol renders as a
    /// blank gap, so the mark is conditional rather than always-present).
    @ViewBuilder
    private func subtitleMenuItem(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isOn {
                // macOS 27 hides SF Symbols in menu items by default. This mark communicates the
                // active audio/subtitle choice, so opt it back in explicitly.
                Label(title, systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
            } else {
                Text(title)
            }
        }
    }

    private func toggleSubtitle(_ id: String) {
        if selectedSubtitleIDs.contains(id) { selectedSubtitleIDs.remove(id) } else { selectedSubtitleIDs.insert(id) }
    }

    /// The menu's current-selection label: "None", the one language, or "N selected".
    private var subtitleSummary: String {
        if selectedSubtitleIDs.isEmpty { return String(localized: "None") }
        if selectedSubtitleIDs.count == 1,
           let track = subtitleTracks.first(where: { $0.id == selectedSubtitleIDs.first }) {
            return subtitleLabel(track)
        }
        return String(localized: "\(selectedSubtitleIDs.count) selected")
    }

    /// A human label for a subtitle track: the manifest's own name, else the language code turned into
    /// a localized language name ("en" → "English"), else the raw id.
    private func subtitleLabel(_ track: MediaTrack) -> String {
        if let name = track.name, !name.isEmpty { return name }
        if let code = track.language, let localized = Locale.current.localizedString(forLanguageCode: code) {
            return localized
        }
        return track.language ?? track.id
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
