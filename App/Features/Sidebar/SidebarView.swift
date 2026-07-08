import SwiftUI
import DownloadModels

/// Smart categories, file-type categories, and user queues. Selecting a row filters the
/// content list.
///
/// Uses a native `List(selection:)` — the standard macOS source list, exactly like Finder: real
/// keyboard navigation (↑/↓), VoiceOver selection semantics, and the system's own selection highlight
/// in every state. The system draws the accent pill when the sidebar has focus and the standard
/// inactive (grey) pill when focus moves to the download list — the OS's way of showing which pane
/// keys go to. We deliberately don't override any of that (an earlier custom pill mismatched the
/// system's press/hover highlight width); the row just supplies content and a `tag`.
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
        let count = model.downloads.lazy.filter(selection.matches).count
        // No forced colors: the native source list renders the label for the current selection/focus
        // state (white on the active accent, primary on the inactive grey) — the count rides along as
        // a dimmed trailing badge, like Mail. This is what keeps it identical to Finder.
        return HStack(spacing: 0) {
            Label(title, systemImage: symbol)
            Spacer(minLength: 8)
            if count > 0 {
                Text("\(count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 1)
        .tag(selection)
        // VoiceOver reads the filter name and its count; the List provides the "selected" trait.
        .accessibilityValue(count > 0 ? Text(verbatim: String(count)) : Text(verbatim: ""))
    }
}
