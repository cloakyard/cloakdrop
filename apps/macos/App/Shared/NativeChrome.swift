import SwiftUI

/// Glass is reserved for floating chrome. Accessibility preferences get an opaque,
/// semantic surface with a visible boundary instead of layered blur and custom shadows.
struct FloatingChrome<Surface: InsettableShape>: ViewModifier {
    let shape: Surface
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.5 : 0.2)))
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

/// The same action hierarchy in every sheet, with system focus, disabled and pressed states.
struct SheetActionStyle: ViewModifier {
    var prominent = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency || contrast == .increased {
                if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
            } else {
                if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
            }
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
    }
}

struct SheetActions<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 12, content: content)
        }
        .modifier(SheetActionStyle())
    }
}
