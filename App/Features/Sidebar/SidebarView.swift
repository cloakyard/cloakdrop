import SwiftUI
import DownloadModels

/// Smart categories, file-type categories, and user queues. Selecting a row filters the
/// content list.
///
/// Uses a native `List(selection:)` so the source list gets real keyboard navigation (↑/↓ move the
/// selection, like Finder) and VoiceOver selection semantics for free — the standard macOS source
/// list. The selected row draws the system's accent highlight (white content on the app accent); an
/// unselected row shows a secondary-tinted icon and a regular label.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: selectionBinding) {
            Section("Library") {
                ForEach(SmartFilter.allCases) { filter in
                    row(.smart(filter), title: filter.localizedName, symbol: filter.systemImage)
                }
            }

            Section("Categories") {
                ForEach(FileCategory.allCases) { category in
                    row(.category(category), title: category.localizedName, symbol: category.systemImage)
                }
            }

            // Only surface the Queues section once there's a queue beyond the default — a lone
            // "Main Queue" just duplicates "All" and adds clutter.
            if model.queues.contains(where: { $0.id != DownloadQueue.defaultQueueID }) {
                Section("Queues") {
                    ForEach(model.queues) { queue in
                        // The seeded default queue gets a localized name; user-created queues
                        // keep their own (user-entered) names verbatim.
                        let name = queue.id == DownloadQueue.defaultQueueID ? String(localized: "Main Queue") : queue.name
                        row(.queue(queue.id), title: name, symbol: "tray.full")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("CloakDrop")
    }

    /// Drives the content filter from the List's single selection; ignores a deselect-to-nil so a
    /// filter is always active.
    private var selectionBinding: Binding<SidebarSelection?> {
        Binding(
            get: { model.effectiveSelection },
            set: { if let selection = $0 { model.selection = selection } }
        )
    }

    private func row(_ selection: SidebarSelection, title: String, symbol: String) -> some View {
        let isSelected = model.effectiveSelection == selection
        let count = model.downloads.lazy.filter(selection.matches).count
        // On the accent selection the whole row goes white; unselected shows a secondary-tinted icon.
        let contentColor: AnyShapeStyle = isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary)
        return HStack(spacing: 0) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(contentColor)
            }
            Spacer(minLength: 8)
            if count > 0 {
                Text("\(count)")
                    .foregroundStyle(contentColor)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 1)
        .tag(selection)
        // VoiceOver reads the filter name and its count; the List provides the "selected" trait.
        .accessibilityValue(count > 0 ? Text(verbatim: String(count)) : Text(verbatim: ""))
    }
}
