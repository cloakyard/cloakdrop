import SwiftUI
import DownloadModels

/// Settings ▸ Stats — download totals first, followed by a compact rank and progress toward the
/// next tier. All counts are local to this Mac (no telemetry) — the footer says so.
struct StatsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showResetConfirm = false

    private var stats: DownloadStats { model.stats }
    private var badge: StatsBadge { DownloadTier.current(for: stats) }

    var body: some View {
        Form {
            Section("Downloaded") {
                LabeledContent("Today", value: bytes(stats.todayBytes))
                LabeledContent("This month", value: bytes(stats.monthBytes))
                LabeledContent("All time", value: bytes(stats.allTimeBytes))
            }
            .monospacedDigit()

            Section("This Month’s Rank") {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        Circle().fill(.tint.opacity(0.15)).frame(width: 48, height: 48)
                        Image(systemName: badge.symbol)
                            .font(.system(size: 24))
                            .foregroundStyle(.tint)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey(badge.title)).font(.headline)
                        Text(LocalizedStringKey(badge.blurb))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            if let next = DownloadTier.next(after: stats.monthBytes) {
                Section {
                    LabeledContent("Next badge") {
                        Label(LocalizedStringKey(next.title), systemImage: next.symbol)
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: DownloadTier.progress(for: stats.monthBytes))
                    LabeledContent("Remaining this month", value: bytes(next.threshold - stats.monthBytes))
                } header: {
                    Text("Next tier")
                }
            }

            Section {
                Button(role: .destructive) { showResetConfirm = true } label: {
                    Text("Reset Stats…")
                }
                .confirmationDialog("Reset download stats?", isPresented: $showResetConfirm, titleVisibility: .visible) {
                    Button("Reset", role: .destructive) { model.resetStats() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This clears today’s, this month’s, and all-time totals. It can’t be undone.")
                }
            } footer: {
                Text("Counted and stored only on this Mac — never uploaded anywhere.")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshStats() }   // so "today" is fresh after a midnight rollover
    }

    private func bytes(_ n: Int64) -> String {
        Format.bytes(max(0, n))
    }
}
