import SwiftUI

/// A compact, circular, tinted action button used for a row's primary action (pause /
/// resume / retry / reveal). Big enough to be an easy, obvious target, with a subtle hover.
struct CircleActionButton: View {
    let symbol: String
    var tint: Color = .accentColor
    /// Localized action name — used for the tooltip *and* the VoiceOver label, so the button
    /// announces "Pause" / "Resume" / … rather than a bare "button".
    let help: LocalizedStringKey
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                // Optically center the play triangle.
                .offset(x: symbol == "play.fill" ? 1 : 0)
                .frame(width: 30, height: 30)
                .background(Circle().fill(tint.opacity(hovering ? 0.28 : 0.16)))
                .overlay(Circle().strokeBorder(tint.opacity(0.2), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}
