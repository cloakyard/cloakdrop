import SwiftUI

/// A compact native heading on the sheet's own surface. Glass belongs to the sheet's
/// actions, not another full-width material band behind its title and context.
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
                    .fixedSize(horizontal: false, vertical: true)
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
    }
}
