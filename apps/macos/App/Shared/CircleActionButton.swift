import SwiftUI

/// A native circular action for a content row. The bordered style supplies system hover,
/// pressed, disabled and keyboard-focus states without introducing glass into the list.
struct CircleActionButton: View {
    let symbol: String
    var tint: Color = .accentColor
    /// Localized action name — used for the tooltip *and* the VoiceOver label, so the button
    /// announces "Pause" / "Resume" / … rather than a bare "button".
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                // Optically center the play triangle.
                .offset(x: symbol == "play.fill" ? 1 : 0)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .tint(tint)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}
