import SwiftUI
import AppKit
import DownloadModels

/// Link grabber: paste a wall of mixed links (or import a `.txt`), and CloakDrop parses, dedupes, and
/// expands range patterns like `file[01-50].zip` into a reviewable list. Each link is analyzed (name,
/// host, type), can be filtered, and individually selected before enqueuing — so a page's worth of
/// links becomes a curated batch, not an all-or-nothing paste.
struct BatchAddSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private struct GrabbedLink: Identifiable, Hashable {
        let url: URL
        var selected: Bool = true
        var id: URL { url }
        var fileName: String { url.lastPathComponent.isEmpty ? url.host ?? url.absoluteString : url.lastPathComponent }
    }

    @State private var text = ""
    @State private var links: [GrabbedLink] = []
    @State private var filter = ""
    @State private var pageURLString = ""
    @State private var isFetchingPage = false
    @State private var pageFetchNote: String?
    @State private var destinationURL = AppEnvironment.defaultDownloadsDirectory()
    @State private var destinationBookmark: Data?

    private var filteredIndices: [Int] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return links.indices.filter { needle.isEmpty || links[$0].url.absoluteString.lowercased().contains(needle) }
    }
    private var selectedCount: Int { links.filter(\.selected).count }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Grab Links", systemImage: "square.stack.3d.down.right.fill")

            VStack(alignment: .leading, spacing: 8) {
                Text("Paste links — one per line. Patterns like `file[01-50].zip` expand automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    TextField("Page URL", text: $pageURLString, prompt: Text("Grab all links from a page…"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { fetchFromPage() }
                    Button {
                        fetchFromPage()
                    } label: {
                        if isFetchingPage {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Fetch Links", systemImage: "arrow.down.doc")
                        }
                    }
                    .disabled(isFetchingPage || AppModel.normalizedURL(pageURLString) == nil)
                }
                if let pageFetchNote {
                    Text(pageFetchNote).font(.caption).foregroundStyle(.secondary)
                }

                TextEditor(text: $text)
                    .font(.callout.monospaced())
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    .onChange(of: text) { _, newValue in reparse(newValue) }

                if !links.isEmpty {
                    grabbedList
                }

                HStack {
                    Button {
                        importTextFile()
                    } label: {
                        Label("Import .txt…", systemImage: "doc.badge.plus")
                    }
                    Spacer()
                    Text(selectedCount == 1 ? "\(selectedCount) selected" : "\(selectedCount) selected")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }

                HStack(spacing: 6) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(destinationURL.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { chooseDestination() }
                }
            }
            .padding(20)

            Divider()

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    model.addURLs(links.filter(\.selected).map(\.url), into: destinationURL, bookmark: destinationBookmark)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedCount == 0)
            }
            .padding()
        }
        .frame(width: 580, height: 600)
    }

    private var grabbedList: some View {
        VStack(spacing: 6) {
            HStack {
                Button(allSelected ? "Deselect All" : "Select All") { toggleAll() }
                    .controlSize(.small)
                Spacer()
                TextField("Filter", text: $filter, prompt: Text("Filter"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
            List {
                ForEach(filteredIndices, id: \.self) { index in
                    Toggle(isOn: Binding(
                        get: { links[index].selected },
                        set: { links[index].selected = $0 }
                    )) {
                        HStack(spacing: 8) {
                            Image(systemName: FileIcon.symbol(forFileName: links[index].fileName))
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(links[index].fileName).lineLimit(1).truncationMode(.middle)
                                Text(links[index].url.host ?? links[index].url.absoluteString)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .frame(minHeight: 200)
        }
    }

    private var allSelected: Bool { !links.isEmpty && links.allSatisfy(\.selected) }

    private func toggleAll() {
        let target = !allSelected
        for index in links.indices { links[index].selected = target }
    }

    /// Re-parse the pasted text into a deduped, pattern-expanded list, preserving prior selection for
    /// links that are still present.
    private func reparse(_ newValue: String) {
        let previouslyDeselected = Set(links.filter { !$0.selected }.map(\.url))
        links = URLBatch.parse(newValue).map { GrabbedLink(url: $0, selected: !previouslyDeselected.contains($0)) }
    }

    /// Fetch the entered page and append its downloadable links to the editor, where the normal
    /// parse/select flow takes over.
    private func fetchFromPage() {
        guard !isFetchingPage, let url = AppModel.normalizedURL(pageURLString) else { return }
        isFetchingPage = true
        pageFetchNote = nil
        Task {
            let found = await model.extractPageLinks(from: url)
            isFetchingPage = false
            guard !found.isEmpty else {
                // Tell the user rather than silently clearing the field with nothing added.
                pageFetchNote = String(localized: "No downloadable links found on that page.")
                return
            }
            let appended = found.map(\.absoluteString).joined(separator: "\n")
            text = text.isEmpty ? appended : text + "\n" + appended
            pageURLString = ""
        }
    }

    private func importTextFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .text]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url,
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        text = text.isEmpty ? contents : text + "\n" + contents
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = destinationURL
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destinationURL = url
        // Persist a security-scoped bookmark so downloads to this folder survive relaunch.
        destinationBookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
