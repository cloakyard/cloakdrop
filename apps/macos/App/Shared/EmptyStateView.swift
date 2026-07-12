import SwiftUI

/// A centered empty-state — icon, title, and optional message/action below.
///
/// Unlike `ContentUnavailableView`, which self-centers its *whole* block (so two side-by-side empty
/// panes with different amounts of content land their titles at different heights), this anchors the
/// icon + title at a consistent fraction from the top. That keeps the list's "No Downloads" and the
/// inspector's "No Selection" titles aligned on the same line, with any message/button flowing below
/// without shifting the title.
struct EmptyStateView<Extra: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    @ViewBuilder var extra: () -> Extra

    init(_ title: LocalizedStringKey, systemImage: String, @ViewBuilder extra: @escaping () -> Extra) {
        self.title = title
        self.systemImage = systemImage
        self.extra = extra
    }

    /// Fraction of the pane's height at which the icon begins — tuned so the title sits in the
    /// upper-middle, matching a standard macOS empty pane while staying identical across panes.
    private let topAnchor: CGFloat = 0.30

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 12) {
                VStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 44, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                extra()
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 32)
            .padding(.top, geo.size.height * topAnchor)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}
