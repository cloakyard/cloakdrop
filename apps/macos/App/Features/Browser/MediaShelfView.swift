import SwiftUI
import DownloadModels

/// The browser's "what can I grab here" popover: sniffed streams/media/files ranked by the core
/// classifier, the page-extraction offer, and honest states for DRM and empty pages.
struct MediaShelfView: View {
    let session: BrowserSession

    private var candidates: [SniffedItem] { session.shelfItems }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if session.media.drmDetected {
                drmNotice
                Divider()
            }
            if candidates.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(candidates) { item in
                            ShelfRow(item: item, pageTitle: session.media.pageTitle) {
                                session.download(item)
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 320)
            }
            Divider()
            footer
        }
        .frame(width: 360)
    }

    private var drmNotice: some View {
        Label {
            Text("This page plays protected (DRM) content, which can’t be downloaded.")
                .font(.caption)
        } icon: {
            Image(systemName: "lock.shield")
        }
        .foregroundStyle(.secondary)
        .padding(10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "play.slash")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No media detected on this page yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Play a video or open a file link, and it will appear here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
    }

    private var footer: some View {
        Button {
            session.extractCurrentPage()
        } label: {
            Label("Extract Media from This Page", systemImage: "sparkles.tv")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .font(.callout)
        .padding(10)
        .help("Read this page with the bundled resolver (YouTube and 1800+ sites) and pick a quality")
        .disabled(session.currentURL == nil || !canExtract)
    }

    private var canExtract: Bool {
        (session.sink?.canExtractFromPages ?? false) && !session.media.drmDetected
    }
}

/// One shelf candidate: type icon, name, host, and the grab button.
private struct ShelfRow: View {
    let item: SniffedItem
    let pageTitle: String
    let action: () -> Void

    @State private var handedOff = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(item.type == .page ? Color.accentColor : .secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                action()
                handedOff = true
            } label: {
                Image(systemName: handedOff ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(handedOff ? Color.green : Color.accentColor)
                    // A comfortable click target — the bare glyph alone is ~18 pt.
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(handedOff)
            .help(grabHelp)
            // `.help` is only a tooltip — VoiceOver needs an explicit name.
            .accessibilityLabel(Text(grabHelp))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Design.cardFill, in: RoundedRectangle(cornerRadius: Design.inlineRadius))
    }

    private var grabHelp: String {
        item.type == .stream ? String(localized: "Grab this stream — you’ll pick the quality")
                             : String(localized: "Download with CloakDrop")
    }

    private var symbol: String {
        switch item.type {
        case .page: return "sparkles.tv"
        case .stream: return "dot.radiowaves.left.and.right"
        case .video: return "film"
        case .audio: return "music.note"
        case .file: return FileIcon.symbol(forFileName: item.filename ?? item.label)
        }
    }

    private var title: String {
        switch item.type {
        case .page:
            return pageTitle.isEmpty ? item.label : pageTitle
        case .stream:
            // A manifest's filename ("master.m3u8") says nothing about the video — show the page
            // title, the name the user actually recognizes. A server-supplied filename still wins.
            if let filename = item.filename { return filename }
            return pageTitle.isEmpty ? item.label : pageTitle
        case .video, .audio, .file:
            return item.filename ?? item.label
        }
    }

    private var subtitle: String {
        let host = MediaSniffer.hostOf(item.url)
        switch item.type {
        case .page: return String(localized: "This page’s video — pick a quality")
        case .stream: return String(localized: "Adaptive stream · \(host)")
        case .video: return String(localized: "Video · \(host)")
        case .audio: return String(localized: "Audio · \(host)")
        case .file: return String(localized: "File · \(host)")
        }
    }
}
