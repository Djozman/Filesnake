import SwiftUI
import AppKit

// MARK: - NSSearchField that aggressively claims first responder

final class FocusableSearchField: NSSearchField {
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Grab first responder before the event propagates
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

// MARK: - SwiftUI wrapper

struct SearchBarView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> FocusableSearchField {
        let field = FocusableSearchField()
        field.placeholderString = "Search files in archive"
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: FocusableSearchField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    // MARK: Coordinator
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding var text: String
        weak var field: FocusableSearchField?

        init(text: Binding<String>) { _text = text }

        // Fires on every keystroke
        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSSearchField else { return }
            text = f.stringValue
        }

        // Escape clears and gives focus back to table
        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.cancelOperation(_:)) {
                text = ""
                field?.stringValue = ""
                field?.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
    }
}
