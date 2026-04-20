import SwiftUI
import AppKit

// NSSearchField wrapped in NSViewRepresentable so it can forcibly claim
// first responder — SwiftUI TextField loses to NSTableView in the responder chain.
struct SearchBarView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search files in archive"
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        // Only update if out of sync to avoid clobbering the user's cursor position
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    // MARK: - Coordinator
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding var text: String
        weak var field: NSSearchField?

        init(text: Binding<String>) { _text = text }

        @objc func searchChanged(_ sender: NSSearchField) {
            text = sender.stringValue
        }

        // NSTextFieldDelegate — fires on every keystroke
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            text = field.stringValue
        }

        // Make the field first responder as soon as the user clicks it
        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                text = ""
                field?.stringValue = ""
                // Return focus to the table
                field?.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
    }
}
