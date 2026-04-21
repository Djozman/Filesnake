import SwiftUI
import AppKit

/// Native NSSearchField wrapped for SwiftUI. Binds directly to a String.
struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search files\u{2026}"
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.controlSize = .regular
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.focusRingType = .none
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        field.heightAnchor.constraint(equalToConstant: 22).isActive = true
        field.setContentHuggingPriority(.required, for: .vertical)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        guard field.currentEditor() == nil else { return }
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding var text: String
        init(text: Binding<String>) { _text = text }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.cancelOperation(_:)) {
                text = ""
                (control as? NSSearchField)?.stringValue = ""
                return true
            }
            return false
        }
    }
}
