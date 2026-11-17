import SwiftUI

/// Start at a useful size while letting native macOS sheets expand for longer content.
struct ResizableSheetLayout: ViewModifier {
    let width: CGFloat
    let height: CGFloat
    let minimumHeight: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(minWidth: width, idealWidth: width, maxWidth: .infinity,
                   minHeight: minimumHeight, idealHeight: height, maxHeight: .infinity)
            .presentationSizing(.fitted)
    }
}

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

/// System actions in fixed or floating chrome. Content rows use ordinary bordered controls.
struct ChromeActionStyle: ViewModifier {
    var prominent = false
    var controlSize: ControlSize = .regular
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
        .controlSize(controlSize)
        .buttonBorderShape(.capsule)
    }
}

/// The same action hierarchy in every sheet, with system focus, disabled and pressed states.
struct SheetActionStyle: ViewModifier {
    var prominent = false

    func body(content: Content) -> some View {
        content.modifier(ChromeActionStyle(prominent: prominent, controlSize: .large))
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
