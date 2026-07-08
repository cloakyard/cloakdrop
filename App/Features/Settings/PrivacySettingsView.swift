import SwiftUI

/// Settings ▸ Privacy: CloakDrop's privacy posture, stated plainly.
struct PrivacySettingsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 46))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .padding(.top, 8)

            Text("Private by design")
                .font(.title2.weight(.semibold))

            Text("CloakDrop is part of the Cloakyard privacy-first suite.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 14) {
                guarantee("Everything runs on-device")
                guarantee("No accounts, analytics, or telemetry")
                guarantee("No connections you didn't choose")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

            Text("""
            CloakDrop never phones home. Your download history and settings stay on this Mac, \
            fully under your control. Every connection is one you chose: your downloads, a \
            proxy you configure, or a speed test you start yourself.
            """)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func guarantee(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Text(text)
            Spacer(minLength: 0)
        }
    }
}
