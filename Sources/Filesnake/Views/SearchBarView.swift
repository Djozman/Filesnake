import SwiftUI
import AppKit

// MARK: - NSSearchField subclass that always wins first-responder
// HSplitView means the search field is a sibling of the table, not nested inside
// the same focus-stealing NSViewRepresentable hierarchy, so this now works reliably.

final class FocusableSearchField: NSSearchField {
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
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

        // Every keystroke
        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSSearchField else { return }
            text = f.stringValue
        }

        // Escape: clear + resign
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
