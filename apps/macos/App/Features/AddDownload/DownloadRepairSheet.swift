import SwiftUI
import DownloadModels

struct DownloadRepairSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let download: Download
    @State private var address = ""
    @State private var message: String?
    @State private var needsRestart = false
    @State private var work: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Repair Download", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
            content
        }
        .frame(width: 480)
        .interactiveDismissDisabled(work != nil)
        .onDisappear { work?.cancel() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(download.fileName).font(.headline).textSelection(.enabled)
            Text("Paste a fresh link to the same file. Compatible saved progress will be reused.")
                .foregroundStyle(.secondary)
            TextField("Replacement URL", text: $address)
                .borderedTextField()
                .onChange(of: address) { _, _ in needsRestart = false; message = nil }
                .disabled(work != nil)
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            SheetActions {
                Button("Cancel", role: .cancel) { work?.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if work != nil { ProgressView().controlSize(.small) }
                Button(needsRestart ? "Restart Download" : "Repair and Resume") { repair() }
                    .keyboardShortcut(.defaultAction)
                    .modifier(SheetActionStyle(prominent: true))
                    .disabled(work != nil || AppModel.normalizedURL(address) == nil)
            }
        }
        .padding(20)
    }

    private func repair() {
        guard let url = AppModel.normalizedURL(address) else { return }
        let restart = needsRestart
        message = nil
        work = Task {
            defer { work = nil }
            do {
                try await model.repairDownload(download.id, url: url, restart: restart)
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                needsRestart = error as? DownloadEditError == .restartRequired || error as? DownloadEditError == .missingPartialData
                message = AppModel.downloadEditMessage(error)
            }
        }
    }
}
