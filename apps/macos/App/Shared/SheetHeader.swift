import SwiftUI

/// A compact, consistent title row for sheets: a tinted glyph and a title, over a faint
/// material so it reads as a header band above the form. An optional subtitle (host, context)
/// and trailing accessory keep sheet-specific details inside the shared chrome instead of each
/// sheet rolling its own header.
struct SheetHeader<Accessory: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    var subtitle: Text?
    @ViewBuilder var accessory: () -> Accessory

    init(
        title: LocalizedStringKey,
        systemImage: String,
        subtitle: Text? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    subtitle
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            accessory()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.regularMaterial)
    }
}
