import SwiftUI
import AppKit
import DownloadModels

/// The kinds of condition the editor can express, each mapping to a `SmartRuleCondition` case.
private enum ConditionKind: String, CaseIterable, Identifiable {
    case fileExtension, fileName, urlHost, url, mimeType, category, largerThan, smallerThan
    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .fileExtension: return "Extension is"
        case .fileName: return "File name contains"
        case .urlHost: return "URL host contains"
        case .url: return "URL contains"
        case .mimeType: return "MIME type contains"
        case .category: return "Category is"
        case .largerThan: return "Larger than"
        case .smallerThan: return "Smaller than"
        }
    }

    var placeholder: LocalizedStringKey {
        switch self {
        case .fileExtension: return "zip, dmg"
        case .fileName: return "installer"
        case .urlHost: return "example.com"
        case .url: return "/downloads/"
        case .mimeType: return "video/"
        default: return ""
        }
    }
}

/// An editable draft of one condition — bridges the typed `SmartRuleCondition` enum to form controls.
private struct DraftCondition: Identifiable {
    let id = UUID()
    var kind: ConditionKind = .fileExtension
    var text: String = ""
    var category: FileCategory = .video
    var sizeMB: Double = 100

    init() {}

    init(_ condition: SmartRuleCondition) {
        switch condition {
        case .fileExtensionIn(let extensions): kind = .fileExtension; text = extensions.joined(separator: ", ")
        case .fileNameContains(let value): kind = .fileName; text = value
        case .urlHostContains(let value): kind = .urlHost; text = value
        case .urlContains(let value): kind = .url; text = value
        case .mimeTypeContains(let value): kind = .mimeType; text = value
        case .categoryIs(let value): kind = .category; category = value
        case .largerThan(let bytes): kind = .largerThan; sizeMB = Double(bytes) / 1_000_000
        case .smallerThan(let bytes): kind = .smallerThan; sizeMB = Double(bytes) / 1_000_000
        }
    }

    /// The typed condition, or `nil` when a text condition was left blank (dropped on save).
    var condition: SmartRuleCondition? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .fileExtension:
            let extensions = text.split { $0 == "," || $0 == " " || $0 == "." }
                .map { String($0).lowercased() }.filter { !$0.isEmpty }
            return extensions.isEmpty ? nil : .fileExtensionIn(extensions)
        case .fileName: return trimmed.isEmpty ? nil : .fileNameContains(trimmed)
        case .urlHost: return trimmed.isEmpty ? nil : .urlHostContains(trimmed)
        case .url: return trimmed.isEmpty ? nil : .urlContains(trimmed)
        case .mimeType: return trimmed.isEmpty ? nil : .mimeTypeContains(trimmed)
        case .category: return .categoryIs(category)
        case .largerThan: return .largerThan(bytesFromMegabytes(sizeMB))
        case .smallerThan: return .smallerThan(bytesFromMegabytes(sizeMB))
        }
    }
}

/// Megabytes → bytes for user-typed values: non-finite input collapses to `minimum`, and the
/// byte result is capped below `Int64.max` so the conversion can never trap on a huge number.
private func bytesFromMegabytes(_ megabytes: Double, minimum: Double = 0) -> Int64 {
    let clamped = megabytes.isFinite ? max(minimum, megabytes) : minimum
    return Int64(min(clamped * 1_000_000, 9e18))
}

/// How a rule should affect a matched download's start behavior.
private enum StartMode: Hashable { case useDefault, start, pause }

/// Create or edit a single smart rule: a name, a set of AND-ed conditions, and the actions to apply.
struct RuleEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let existing: SmartRule?

    @State private var name: String
    @State private var conditions: [DraftCondition]
    @State private var destinationPath: String?
    @State private var destinationBookmark: Data?
    @State private var assignedQueueID: UUID?
    @State private var limitSpeed: Bool
    @State private var speedMBs: Double
    @State private var startMode: StartMode

    init(rule: SmartRule?) {
        existing = rule
        _name = State(initialValue: rule?.name ?? "")
        _conditions = State(initialValue: rule?.conditions.map(DraftCondition.init) ?? [DraftCondition()])

        var destination: String?
        var bookmark: Data?
        var queue: UUID?
        var limit = false
        var speed = 5.0
        var start = StartMode.useDefault
        for action in rule?.actions ?? [] {
            switch action {
            case .setDestination(let path, let mark): destination = path; bookmark = mark
            case .assignQueue(let id): queue = id
            case .limitSpeed(let bytesPerSecond): limit = true; speed = Double(bytesPerSecond) / 1_000_000
            case .autoStart(let value): start = value ? .start : .pause
            }
        }
        _destinationPath = State(initialValue: destination)
        _destinationBookmark = State(initialValue: bookmark)
        _assignedQueueID = State(initialValue: queue)
        _limitSpeed = State(initialValue: limit)
        _speedMBs = State(initialValue: speed)
        _startMode = State(initialValue: start)
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: existing == nil ? "New Rule" : "Edit Rule", systemImage: "arrow.triangle.branch")

            Form {
                Section("Name") {
                    TextField("Rule name", text: $name, prompt: Text("e.g. Videos to Movies"))
                        .textFieldStyle(.roundedBorder)
                }

                Section {
                    ForEach($conditions) { $condition in
                        conditionRow($condition)
                    }
                    Button {
                        conditions.append(DraftCondition())
                    } label: {
                        Label("Add Condition", systemImage: "plus")
                    }
                } header: {
                    Text("When")
                } footer: {
                    if conditions.isEmpty {
                        Text("With no conditions, this rule applies to every download.")
                    } else {
                        Text("All conditions must match.")
                    }
                }

                Section("Then") {
                    HStack {
                        Text("Save to folder")
                        Spacer()
                        if let destinationPath {
                            Text((destinationPath as NSString).lastPathComponent)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Button(destinationPath == nil ? "Choose…" : "Change…") { chooseFolder() }
                        if destinationPath != nil {
                            Button {
                                destinationPath = nil
                                destinationBookmark = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Clear folder")
                        }
                    }
                    Picker("Add to queue", selection: $assignedQueueID) {
                        Text("Don’t change").tag(UUID?.none)
                        ForEach(model.queues) { queue in
                            Text(queueName(queue)).tag(UUID?.some(queue.id))
                        }
                    }
                    Toggle("Limit speed", isOn: $limitSpeed)
                    if limitSpeed {
                        HStack {
                            Text("Maximum")
                            Spacer()
                            TextField("5", value: $speedMBs, format: .number)
                                .labelsHidden()
                                .frame(width: 70)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .accessibilityLabel("Maximum")
                            Text("MB/s").foregroundStyle(.secondary)
                        }
                    }
                    Picker("Start", selection: $startMode) {
                        Text("Use default").tag(StartMode.useDefault)
                        Text("Start immediately").tag(StartMode.start)
                        Text("Add paused").tag(StartMode.pause)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)

            Divider()

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding()
        }
        // Comfortable sheet size for the rule form (the hosting Settings window is wider).
        .frame(width: 480, height: 540)
    }

    @ViewBuilder
    private func conditionRow(_ condition: Binding<DraftCondition>) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: condition.kind) {
                ForEach(ConditionKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .labelsHidden()
            // Size to the longest label so no locale's condition names get clipped.
            .fixedSize()

            switch condition.wrappedValue.kind {
            case .category:
                Picker("", selection: condition.category) {
                    ForEach(FileCategory.allCases) { category in
                        Text(category.localizedName).tag(category)
                    }
                }
                .labelsHidden()
            case .largerThan, .smallerThan:
                TextField("100", value: condition.sizeMB, format: .number)
                    .labelsHidden()
                    .frame(width: 70)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("Size in megabytes")
                Text("MB").foregroundStyle(.secondary)
            default:
                TextField(condition.wrappedValue.kind.placeholder, text: condition.text)
                    .textFieldStyle(.roundedBorder)
            }

            Spacer(minLength: 0)

            Button {
                conditions.removeAll { $0.id == condition.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove condition")
        }
    }

    private func queueName(_ queue: DownloadQueue) -> String {
        queue.id == DownloadQueue.defaultQueueID ? String(localized: "Main Queue") : queue.name
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        if let destinationPath { panel.directoryURL = URL(fileURLWithPath: destinationPath) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destinationPath = url.path
        destinationBookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func save() {
        var actions: [SmartRuleAction] = []
        if let destinationPath { actions.append(.setDestination(path: destinationPath, bookmark: destinationBookmark)) }
        if let assignedQueueID { actions.append(.assignQueue(assignedQueueID)) }
        if limitSpeed { actions.append(.limitSpeed(bytesPerSecond: bytesFromMegabytes(speedMBs, minimum: 0.1))) }
        switch startMode {
        case .useDefault: break
        case .start: actions.append(.autoStart(true))
        case .pause: actions.append(.autoStart(false))
        }

        let rule = SmartRule(
            id: existing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            isEnabled: existing?.isEnabled ?? true,
            order: existing?.order ?? model.nextRuleOrder,
            conditions: conditions.compactMap(\.condition),
            actions: actions
        )
        model.saveRule(rule)
        dismiss()
    }
}
