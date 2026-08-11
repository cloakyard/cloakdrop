import SwiftUI
import DownloadModels

/// The "Rules" settings tab: create, edit, reorder, enable, and delete on-device routing rules that
/// automatically file downloads as they're added.
struct RulesSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var editingRule: SmartRule?
    @State private var isEditorPresented = false

    var body: some View {
        VStack(spacing: 0) {
            if model.rules.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(model.rules) { rule in
                        RuleRow(rule: rule) { edit(rule) }
                    }
                    .onMove { model.moveRules(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.inset)
                // Like the download catalog, this List replaces an empty placeholder when the
                // first rule is added. Keep its two-line rows from inheriting macOS's compact
                // estimate until a later scroll forces remeasurement.
                .environment(\.defaultMinListRowHeight, 40)
            }

            Divider()
            HStack(spacing: 8) {
                Button { addRule() } label: { Label("Add Rule", systemImage: "plus") }
                Spacer()
                Text("Rules apply top to bottom — the first match wins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $isEditorPresented) {
            RuleEditorView(rule: editingRule)
        }
    }

    private var emptyState: some View {
        EmptyStateView("No Rules", systemImage: "arrow.triangle.branch") {
            Text("Route downloads into folders or queues by URL, type, or size — all on your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
    }

    private func addRule() {
        editingRule = nil
        isEditorPresented = true
    }

    private func edit(_ rule: SmartRule) {
        editingRule = rule
        isEditorPresented = true
    }
}

/// One rule in the list: an enable switch, its name, a one-line summary, and a chevron to edit.
private struct RuleRow: View {
    @Environment(AppModel.self) private var model
    let rule: SmartRule
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { var updated = rule; updated.isEnabled = $0; model.saveRule(updated) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel(Text(rule.name))

            // A real button (not a tap gesture), so editing is reachable by keyboard and exposed
            // to VoiceOver as an action — the chevron promises navigation, the button delivers it.
            Button(action: onEdit) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.name)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(rule.isEnabled ? .primary : .secondary)
                        Text(RuleSummary.text(for: rule, queues: model.queues))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit this rule")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Edit") { onEdit() }
            Button("Delete", role: .destructive) { model.deleteRule(rule.id) }
        }
    }
}

/// Builds the compact secondary line describing what a rule does, in the user's language.
enum RuleSummary {
    static func text(for rule: SmartRule, queues: [DownloadQueue]) -> String {
        let actions = rule.actions.map { label(for: $0, queues: queues) }.joined(separator: " · ")
        let effect = actions.isEmpty ? String(localized: "No actions") : actions
        if rule.conditions.isEmpty {
            return String(localized: "Every download") + " · " + effect
        }
        return effect
    }

    private static func label(for action: SmartRuleAction, queues: [DownloadQueue]) -> String {
        switch action {
        case .setDestination(let path, _):
            return String(localized: "Save to \((path as NSString).lastPathComponent)")
        case .assignQueue(let id):
            let queue = queues.first { $0.id == id }
            let name = queue.map { $0.id == DownloadQueue.defaultQueueID ? String(localized: "Main Queue") : $0.name }
                ?? String(localized: "Main Queue")
            return String(localized: "Queue: \(name)")
        case .limitSpeed:
            return String(localized: "Speed limit")
        case .autoStart(let start):
            return start ? String(localized: "Start automatically") : String(localized: "Add paused")
        }
    }
}
