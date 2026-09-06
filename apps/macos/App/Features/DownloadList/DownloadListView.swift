import SwiftUI
import DownloadModels

/// The content column: searchable, sortable, multi-selectable list of downloads with a
/// Liquid Glass toolbar above it.
struct DownloadListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    /// Window key/active state — selection loses its accent emphasis when the window resigns.
    @Environment(\.controlActiveState) private var controlActiveState
    /// Whether the list itself owns keyboard focus; with an inactive window or focus elsewhere
    /// (search field, inspector), macOS draws the gray unemphasized highlight instead.
    @FocusState private var listFocused: Bool

    /// The downloads awaiting "delete the file(s) from disk too?" confirmation (one or many,
    /// depending on the selection the row menu acted on).
    @State private var pendingFileDeletes: [Download] = []

    var body: some View {
        @Bindable var model = model
        Group {
            if model.filteredDownloads.isEmpty {
                // Float the banners over the placeholder: an inset would shrink this pane and push
                // the empty state's fractional anchor out of line with the inspector's (its title is
                // meant to sit on the same line as "No Selection" — see EmptyStateView).
                emptyState
                    .overlay(alignment: .top) { banners }
            } else {
                // With real rows, the banners must push content down, never cover it.
                list
                    .safeAreaInset(edge: .top) { banners }
            }
        }
        .navigationTitle(model.effectiveSelection.title)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search downloads")
        .toolbar { toolbarContent }
        .onChange(of: model.filteredDownloads.map(\.id)) { _, visibleIDs in
            model.selectedDownloadIDs.formIntersection(visibleIDs)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.acceptDrop(urls: urls, strings: [])
        }
        .dropDestination(for: String.self) { strings, _ in
            model.acceptDrop(urls: [], strings: strings)
        }
        .confirmationDialog(
            pendingFileDeletes.count > 1 ? "Delete these files from your Mac?" : "Delete this file from your Mac?",
            isPresented: Binding(get: { !pendingFileDeletes.isEmpty }, set: { if !$0 { pendingFileDeletes = [] } }),
            titleVisibility: .visible
        ) {
            Button(deleteButtonTitle, role: .destructive) {
                pendingFileDeletes.forEach { model.remove($0.id, deleteFile: true) }
                pendingFileDeletes = []
            }
            Button("Cancel", role: .cancel) { pendingFileDeletes = [] }
        } message: {
            if pendingFileDeletes.count > 1 {
                Text("\(pendingFileDeletes.count) files will be permanently deleted. This can’t be undone.")
            } else if let only = pendingFileDeletes.first {
                Text("“\(only.fileName)” will be permanently deleted. This can’t be undone.")
            }
        }
    }

    private var deleteButtonTitle: LocalizedStringKey {
        pendingFileDeletes.count > 1 ? "Delete \(pendingFileDeletes.count) Files" : "Delete File"
    }

    /// The transient capture/clipboard banners, stacked. Floated over the empty state (keeping the
    /// pane's full height) or inset above the list (pushing rows down) — see `body`.
    private var banners: some View {
        VStack(spacing: 6) {
            clipboardBanner
        }
    }

    @ViewBuilder
    private var clipboardBanner: some View {
        if let url = model.detectedClipboardURL {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Link copied")
                        .font(.callout.weight(.medium))
                    Text(url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Add") { model.addDetectedClipboardURL() }
                    .buttonStyle(.borderedProminent)
                Button {
                    model.dismissDetectedClipboardURL()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
            .accessibilityElement(children: .contain)
            .padding(10)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: Design.cardRadius))
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var list: some View {
        @Bindable var model = model
        return List(selection: $model.selectedDownloadIDs) {
            ForEach(model.filteredDownloads) { download in
                DownloadRowView(download: download)
                    .tag(download.id)
                    .contextMenu { rowMenu(download) }
            }
        }
        .listStyle(.inset)
        // macOS can reuse the compact system default while this List replaces the empty state,
        // leaving freshly inserted download rows clipped until a scroll triggers remeasurement.
        // The standard rendered row is 60 points tall (40-point icon, content padding, and List's
        // row insets), so make that invariant part of List rather than relying on its first estimate.
        .environment(\.defaultMinListRowHeight, 60)
        .focused($listFocused)
        // Move keyboard navigation into the list when a row is clicked. Otherwise SwiftUI can
        // leave focus in the sidebar even though the download selection visibly changed.
        .simultaneousGesture(TapGesture().onEnded { listFocused = true })
        // Tell the rows whether selection is drawn emphasized (accent) or unemphasized (gray),
        // mirroring AppKit's backgroundStyle: focused list in an active window.
        .environment(\.selectionEmphasis, listFocused && controlActiveState != .inactive)
        .onDeleteCommand { model.removeSelected(deleteFile: false) }
    }

    @ViewBuilder
    private var emptyState: some View {
        // All three states render through EmptyStateView so the title stays on the same line as the
        // inspector's "No Selection" (ContentUnavailableView self-centers and would break that).
        if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            EmptyStateView("No Results", systemImage: "magnifyingglass") {
                Text("No downloads match “\(model.searchText)”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if model.downloads.isEmpty {
            EmptyStateView("No Downloads", systemImage: "arrow.down.circle") {
                Text("Add a URL to start downloading. CloakDrop splits files into parallel streams for speed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Add Download…") { model.isAddSheetPresented = true }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        } else {
            EmptyStateView("Nothing Here", systemImage: model.effectiveSelection.emptySymbol) {
                Text("No downloads in “\(model.effectiveSelection.title)”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Toolbar

    private var hasPausable: Bool {
        model.downloads.contains { $0.status == .downloading || $0.status == .queued }
    }
    private var hasResumable: Bool {
        model.downloads.contains { $0.status.isResumable }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Add Download…") { model.isAddSheetPresented = true }
                Button("Grab Links…") { model.isBatchSheetPresented = true }
            } label: {
                Label("Add Download", systemImage: "plus")
            } primaryAction: {
                model.isAddSheetPresented = true
            }
            .help("Add a new download (⌘N) — or a batch from the menu")
        }

        ToolbarItem {
            Button {
                openWindow(id: BrowserScene.windowID)
            } label: {
                Label("Browser", systemImage: "globe")
            }
            .help("Open the built-in browser — browse any site and grab its media (⇧⌘B)")
        }

        ToolbarItemGroup {
            Button {
                model.pauseAll()
            } label: {
                Label("Pause All", systemImage: "pause.circle")
            }
            .help("Pause all active downloads")
            .disabled(!hasPausable)

            Button {
                model.resumeAll()
            } label: {
                Label("Resume All", systemImage: "play.circle")
            }
            .help("Resume all paused downloads")
            .disabled(!hasResumable)

            Menu {
                Picker("Sort By", selection: Binding(get: { model.sort }, set: { model.sort = $0 })) {
                    ForEach(DownloadSort.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort the list")
        }
    }

    // MARK: Per-row context menu

    /// The rows a row action applies to: the whole selection when the clicked row is part of a
    /// multi-selection (standard macOS behaviour), otherwise just the clicked row.
    private func actionTargets(for download: Download) -> [Download] {
        if model.selectedDownloadIDs.contains(download.id), model.selectedDownloadIDs.count > 1 {
            return model.filteredDownloads.filter { model.selectedDownloadIDs.contains($0.id) }
        }
        return [download]
    }

    @ViewBuilder
    private func rowMenu(_ download: Download) -> some View {
        let targets = actionTargets(for: download)

        if targets.contains(where: { $0.status.isActive }) {
            Button("Pause") { targets.forEach { model.pause($0.id) } }
        }
        if targets.contains(where: { $0.status.isResumable }) {
            Button("Resume") { targets.forEach { model.resume($0.id) } }
        }
        // Open / Reveal target a specific file, so only offer them for a single completed download.
        if targets.count == 1, download.status == .completed {
            Button("Open") { model.open(download) }
            Button("Reveal in Finder") { model.revealInFinder(download) }
        }
        Divider()
        Button("Copy Source URL") { model.copyURLs(targets) }
        Divider()
        Button("Remove from List") { targets.forEach { model.remove($0.id, deleteFile: false) } }
        Button("Remove and Delete File…", role: .destructive) { pendingFileDeletes = targets }
    }
}
