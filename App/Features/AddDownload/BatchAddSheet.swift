import SwiftUI
import AppKit
import DownloadModels

/// Bulk add: paste a list of URLs (one per line), import a `.txt`, or use range patterns
/// like `file[01-50].zip`. Shows a live count of how many links will be queued.
struct BatchAddSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var destinationURL = AppEnvironment.defaultDownloadsDirectory()
    @State private var destinationBookmark: Data?
    /// Parsed once per text change rather than on every render (a big paste with range patterns
    /// can expand to thousands of URLs — re-parsing it three times per frame would jank).
    @State private var parsedCount = 0

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Add Batch", systemImage: "square.stack.3d.down.right.fill")

            VStack(alignment: .leading, spacing: 8) {
                Text("Paste URLs — one per line. Patterns like `file[01-50].zip` expand automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                TextEditor(text: $text)
                    .font(.callout.monospaced())
                    .frame(minHeight: 200)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    .onChange(of: text) { _, newValue in parsedCount = URLBatch.parse(newValue).count }

                HStack {
                    Button {
                        importTextFile()
                    } label: {
                        Label("Import .txt…", systemImage: "doc.badge.plus")
                    }
                    Spacer()
                    Text(parsedCount == 1 ? "\(parsedCount) link" : "\(parsedCount) links")
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
                    model.batchAdd(text: text, into: destinationURL, bookmark: destinationBookmark)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parsedCount == 0)
            }
            .padding()
        }
        .frame(width: 560, height: 520)
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
