import AppKit
import SwiftUI

/// A borderless, single-line address field backed directly by `NSTextField` so its **focus ring is
/// removed** (`focusRingType = .none`). SwiftUI's plain `TextField` still paints a system focus ring
/// whose corner radius doesn't match our rounded container; owning the AppKit view lets the *only*
/// focus decoration be the ring `BrowserView` draws on the container, so highlight and container
/// share one shape exactly. Focus is bridged both ways: the field reports begin/end editing, and a
/// bumped `focusRequest` token asks it to become first responder (⌘L, clicking the idle bar).
struct URLTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// Drives what's visible: the field stays first-responder-capable (alpha 1) at all times, so
    /// hiding it via opacity — which would block `makeFirstResponder` and deadlock the idle→edit
    /// tap — is avoided; when idle we clear the text color instead and the bar's own overlay shows
    /// the favicon + domain.
    var isEditing: Bool
    var focusRequest: Int
    var onEditingChanged: (Bool) -> Void
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> FocusReportingTextField {
        let field = FocusReportingTextField()
        field.focusRingType = .none
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.font = .preferredFont(forTextStyle: .callout)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.allowsEditingTextAttributes = false
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // becomeFirstResponder fires reliably for programmatic focus (controlTextDidBeginEditing does
        // not); pair it with controlTextDidEndEditing for the resign edge.
        field.onBecomeFirstResponder = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onEditingChanged(true)
        }
        return field
    }

    func updateNSView(_ field: FocusReportingTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        // Idle: keep the field mounted and focusable but invisible (clear text, no placeholder) —
        // the overlay shows the favicon + domain. Editing: reveal the URL.
        field.textColor = isEditing ? .labelColor : .clear
        field.placeholderString = isEditing ? placeholder : ""
        // A new focus request (⌘L / idle-bar tap) makes the field first responder and selects all,
        // matching how clicking Safari's address bar reveals and highlights the whole URL.
        if focusRequest != context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                window.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: URLTextField
        var lastFocusRequest = 0

        init(_ parent: URLTextField) { self.parent = parent }

        func controlTextDidEndEditing(_ obj: Notification) { parent.onEditingChanged(false) }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                control.window?.makeFirstResponder(nil)   // resign → idle state, like Safari after Return
                return true
            }
            return false
        }
    }
}

/// An `NSTextField` that reports when it becomes first responder — the reliable signal for
/// programmatic focus (`controlTextDidBeginEditing` doesn't fire for `makeFirstResponder`).
final class FocusReportingTextField: NSTextField {
    var onBecomeFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let began = super.becomeFirstResponder()
        if began {
            onBecomeFirstResponder?()
            window?.invalidateCursorRects(for: self)   // swap the idle arrow for the editing I-beam
        }
        return began
    }

    override func resetCursorRects() {
        // While idle the pill is a click-to-edit button (and the reload control is overlaid on the
        // trailing edge), so show the arrow — not the I-beam, which would otherwise bleed out from
        // under the button. Once editing, the field editor owns the cursor and shows the I-beam over
        // the text.
        if currentEditor() == nil {
            addCursorRect(bounds, cursor: .arrow)
        } else {
            super.resetCursorRects()
        }
    }
}
