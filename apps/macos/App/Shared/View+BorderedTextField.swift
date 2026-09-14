import SwiftUI

extension View {
    /// Follow the current system text-field style while preserving macOS 26 compatibility.
    @ViewBuilder
    func borderedTextField() -> some View {
        if #available(macOS 27.0, *) {
            textFieldStyle(.bordered)
        } else {
            textFieldStyle(.roundedBorder)
        }
    }
}
