import AppKit
import SwiftUI
import DownloadModels

struct PlaylistImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var playlist: MediaPlaylist?
    @State private var selectedIDs: Set<Int> = []
    @State private var quality = MediaPageSelection.Quality.best
    @State private var outputFormat = MediaOutputFormat.compatibleMP4
    @State private var directory = AppEnvironment.defaultDownloadsDirectory()
    @State private var bookmark: Data?
    @State private var message: String?
    @State private var work: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Import Playlist", systemImage: "list.bullet.rectangle")
            content
        }
        .frame(width: 570)
        .interactiveDismissDisabled(work != nil)
        .onDisappear { work?.cancel() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("Playlist URL", text: $address).borderedTextField()
                    .onSubmit { readPlaylist() }
                    .onChange(of: address) { _, _ in playlist = nil; selectedIDs = []; message = nil }
                Button("Read Playlist") { readPlaylist() }
                    .disabled(AppModel.normalizedURL(address) == nil)
            }
            .disabled(work != nil)
            if let playlist { preview(playlist) }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            if work != nil { ProgressView("Preparing playlist…").controlSize(.small) }
            options.disabled(work != nil)
            Divider()
            SheetActions {
                Button("Cancel", role: .cancel) { work?.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add Selected") { addSelected() }
                    .keyboardShortcut(.defaultAction)
                    .modifier(SheetActionStyle(prominent: true))
                    .disabled(work != nil || playlist == nil || selectedIDs.isEmpty)
            }
        }
        .padding(20)
    }

    private func preview(_ playlist: MediaPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(playlist.title).font(.headline).lineLimit(2)
            HStack {
                Button("Select All") { selectedIDs = Set(playlist.entries.filter(canSelect).map(\.id)) }
                Button("Deselect All") { selectedIDs = [] }
                Spacer()
                Text("\(selectedIDs.count) selected").foregroundStyle(.secondary)
            }
            List(playlist.entries) { entry in
                Toggle(isOn: Binding(
                    get: { selectedIDs.contains(entry.id) },
                    set: { if $0 { selectedIDs.insert(entry.id) } else { selectedIDs.remove(entry.id) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(entry.index). \(entry.title)").lineLimit(2)
                        if !canSelect(entry) { Text("Unavailable or already added").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .disabled(!canSelect(entry))
            }
            .frame(height: 220)
            .listStyle(.inset)
            if playlist.hasMore { Text("Only the first 100 items are shown.").font(.caption).foregroundStyle(.secondary) }
        }
        .disabled(work != nil)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Quality", selection: $quality) {
                Text("Best Available").tag(MediaPageSelection.Quality.best)
                Text("Up to 1080p").tag(MediaPageSelection.Quality.hd1080)
                Text("Up to 720p").tag(MediaPageSelection.Quality.hd720)
                Text("Audio Only").tag(MediaPageSelection.Quality.audioOnly)
            }
            if quality != .audioOnly {
                Picker("Format", selection: $outputFormat) {
                    Text("MP4 (compatible)").tag(MediaOutputFormat.compatibleMP4)
                    Text("Original quality").tag(MediaOutputFormat.original)
                }
            }
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(directory.path).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") { chooseFolder() }
            }
            Text("Selected items are saved in a numbered playlist folder. Unavailable qualities fail individually.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func canSelect(_ entry: MediaPlaylistEntry) -> Bool {
        guard let url = entry.pageURL else { return false }
        return !model.downloads.contains { $0.url == url }
    }

    private func readPlaylist() {
        guard work == nil, let url = AppModel.normalizedURL(address) else { return }
        message = nil
        work = Task {
            defer { work = nil }
            do {
                let result = try await model.readPlaylist(url)
                try Task.checkCancellation()
                playlist = result
                selectedIDs = Set(result.entries.filter(canSelect).map(\.id))
            } catch is CancellationError { return } catch { message = AppModel.playlistMessage(error) }
        }
    }

    private func addSelected() {
        guard let playlist else { return }
        message = nil
        work = Task {
            defer { work = nil }
            do {
                try await model.importPlaylist(playlist, selectedIDs: selectedIDs,
                                               selection: MediaPageSelection(quality: quality, outputFormat: outputFormat),
                                               directory: directory, bookmark: bookmark)
                dismiss()
            } catch is CancellationError { return } catch { message = AppModel.playlistMessage(error) }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: [.pathKey])
            directory = url
        } catch { message = AppModel.downloadEditMessage(error) }
    }
}
