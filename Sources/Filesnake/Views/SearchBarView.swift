import SwiftUI
import AppKit

// MARK: - Search field
// Strategy: intercept keyDown at the window level via NSEvent.addLocalMonitorForEvents.
// When the user types a printable character and the search field is NOT already
// first responder, we make it first responder and forward the character.
// This is how Finder/Xcode-style "type to search" works — no responder-chain fighting.

final class FocusableSearchField: NSSearchField {
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

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
        context.coordinator.installKeyMonitor(for: field)
        return field
    }

    func updateNSView(_ field: FocusableSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    // MARK: - Coordinator
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding var text: String
        weak var field: FocusableSearchField?
        private var monitor: Any?

        init(text: Binding<String>) { _text = text }

        deinit {
            if let m = monitor { NSEvent.removeMonitor(m) }
        }

        func installKeyMonitor(for field: FocusableSearchField) {
            self.field = field
            // Remove any previous monitor
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak field] event in
                guard let self, let field, let window = field.window else { return event }
                // Only intercept when search field is NOT already first responder
                guard !(window.firstResponder is NSText &&
                        (window.firstResponder as? NSText)?.delegate === field) else {
                    return event
                }
                // Only printable characters (ignore cmd/ctrl shortcuts)
                let mods = event.modifierFlags.intersection([.command, .control, .option])
                guard mods.isEmpty,
                      let chars = event.charactersIgnoringModifiers,
                      !chars.isEmpty,
                      chars.unicodeScalars.first.map({ $0.value >= 32 }) == true else {
                    return event
                }
                // Make search field first responder and forward the keystroke
                window.makeFirstResponder(field)
                field.currentEditor()?.insertText(chars, replacingRange: field.currentEditor()!.selectedRange)
                self.text = field.stringValue
                return nil // consume the event
            }
        }

        // Fires on every keystroke once field is focused
        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSSearchField else { return }
            text = f.stringValue
        }

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
