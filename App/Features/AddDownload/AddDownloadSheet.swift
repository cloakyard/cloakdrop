import SwiftUI
import AppKit
import DownloadModels

/// The "add download" sheet: URL (pre-filled from the clipboard when it holds a link),
/// destination, segment count, and an optional checksum to verify against.
struct AddDownloadSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var urlString = ""
    @State private var fileName = ""
    /// The last filename we auto-derived from the URL. While the field still holds this value
    /// (or is empty) we keep syncing it as the URL changes; once the user types their own name
    /// it differs and we stop overwriting. This keeps derivation correct even when the URL is
    /// entered one character at a time, instead of locking onto an early partial value.
    @State private var lastAutoName = ""
    @State private var destinationURL = AppEnvironment.defaultDownloadsDirectory()
    @State private var destinationBookmark: Data?
    @State private var segmentCount = 8
    @State private var checksumAlgorithm: ChecksumAlgorithm = .sha256
    @State private var checksumHex = ""
    @State private var startImmediately = true
    @State private var scheduleEnabled = false
    @State private var scheduledDate = Date().addingTimeInterval(3600)
    @State private var recurrence: ScheduleRecurrence = .none
    @State private var username = ""
    @State private var password = ""
    @State private var referrer = ""
    @State private var cookies = ""

    private var resolvedURL: URL? { AppModel.normalizedURL(urlString) }
    private var canAdd: Bool { resolvedURL != nil }

    /// True when the user typed something in the checksum field that isn't a valid digest, so
    /// we can warn that it won't be used rather than silently dropping it.
    private var checksumIsMalformed: Bool {
        let trimmed = checksumHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !ChecksumExpectation(algorithm: checksumAlgorithm, expectedHex: trimmed).isWellFormed
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "New Download", systemImage: "arrow.down.circle.fill")

            Form {
                Section("Source") {
                    TextField("URL", text: $urlString, prompt: Text("https://example.com/file.zip"))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: urlString) { _, _ in deriveFileNameIfNeeded() }
                    TextField("Save As", text: $fileName, prompt: Text("File name"))
                        .textFieldStyle(.roundedBorder)
                }

                Section("Destination") {
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(destinationURL.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…") { chooseDestination() }
                    }
                }

                Section("Options") {
                    Stepper(value: $segmentCount, in: 1...model.settings.maxSegmentCount) {
                        LabeledContent("Connections", value: "\(segmentCount)")
                    }
                    Toggle("Start immediately", isOn: $startImmediately)
                        .disabled(scheduleEnabled)
                    Toggle("Schedule for later", isOn: $scheduleEnabled.animation(.smooth(duration: 0.2)))
                    if scheduleEnabled {
                        DatePicker("Start at", selection: $scheduledDate, in: Date()...)
                            .datePickerStyle(.compact)
                        Picker("Repeat", selection: $recurrence) {
                            ForEach(ScheduleRecurrence.allCases) { Text($0.localizedLabel).tag($0) }
                        }
                    }
                }

                Section {
                    DisclosureGroup("Authentication") {
                        TextField("Username", text: $username)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Password", text: $password, prompt: Text("HTTP Basic/Digest"))
                            .textFieldStyle(.roundedBorder)
                    }
                    DisclosureGroup("Referrer & cookies") {
                        TextField("Referrer", text: $referrer, prompt: Text("https://example.com"))
                            .textFieldStyle(.roundedBorder)
                        TextField("Cookies", text: $cookies, prompt: Text("name=value; name2=value2"))
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())
                    }
                    DisclosureGroup("Verify checksum") {
                        Picker("Algorithm", selection: $checksumAlgorithm) {
                            ForEach(ChecksumAlgorithm.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        TextField("Expected hash", text: $checksumHex, prompt: Text("Optional hex digest"))
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())
                        if checksumIsMalformed {
                            Label("Not a valid \(checksumAlgorithm.displayName) digest — this file won’t be verified.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
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
                Button(scheduleEnabled ? "Schedule" : "Add Download") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
            .padding()
        }
        .frame(width: 520, height: 600)
        .onAppear(perform: prefill)
    }

    // MARK: Actions

    private func prefill() {
        // A pending URL (from a clipboard banner or drop) wins over the live clipboard.
        if let pending = model.pendingAddURL {
            urlString = pending
            model.pendingAddURL = nil
            deriveFileNameIfNeeded()
            return
        }
        guard urlString.isEmpty,
              let clip = NSPasteboard.general.string(forType: .string),
              AppModel.normalizedURL(clip) != nil else { return }
        urlString = clip.trimmingCharacters(in: .whitespacesAndNewlines)
        deriveFileNameIfNeeded()
    }

    private func deriveFileNameIfNeeded() {
        guard let url = resolvedURL else { return }
        // Never clobber a name the user typed: only overwrite while the field still holds the
        // value we last derived (or is empty).
        guard fileName.isEmpty || fileName == lastAutoName else { return }
        let last = url.lastPathComponent
        let derived = (last.isEmpty || last == "/") ? "download" : last
        fileName = derived
        lastAutoName = derived
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
        destinationBookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func add() {
        guard let url = resolvedURL else { return }
        let trimmedHex = checksumHex.trimmingCharacters(in: .whitespacesAndNewlines)
        let checksum: ChecksumExpectation? = {
            guard !trimmedHex.isEmpty else { return nil }
            let expectation = ChecksumExpectation(algorithm: checksumAlgorithm, expectedHex: trimmedHex)
            return expectation.isWellFormed ? expectation : nil
        }()

        func trimmedOrNil(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let request = DownloadRequest(
            url: url,
            suggestedFileName: fileName.isEmpty ? nil : fileName,
            destinationDirectoryPath: destinationURL.path,
            destinationBookmark: destinationBookmark,
            segmentCount: segmentCount,
            checksum: checksum,
            scheduledStart: scheduleEnabled ? scheduledDate : nil,
            recurrence: scheduleEnabled ? recurrence : .none,
            startImmediately: scheduleEnabled ? false : startImmediately,
            username: trimmedOrNil(username),
            password: password.isEmpty ? nil : password,
            referrer: trimmedOrNil(referrer),
            cookies: trimmedOrNil(cookies)
        )
        model.grab(request)
        dismiss()
    }
}
