import SwiftUI
import AppKit

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

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding var text: String
        weak var field: FocusableSearchField?
        private var monitor: Any?

        init(text: Binding<String>) { _text = text }

        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }

        func installKeyMonitor(for field: FocusableSearchField) {
            self.field = field
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak field] event in
                guard let self, let field, let window = field.window else { return event }
                let alreadyFocused = window.firstResponder === field.currentEditor()
                    || window.firstResponder === field
                guard !alreadyFocused else { return event }
                let mods = event.modifierFlags.intersection([.command, .control, .option])
                guard mods.isEmpty,
                      let chars = event.charactersIgnoringModifiers,
                      !chars.isEmpty,
                      chars.unicodeScalars.first.map({ $0.value >= 32 }) == true
                else { return event }
                window.makeFirstResponder(field)
                field.currentEditor()?.insertText(chars)
                self.text = field.stringValue
                return nil
            }
        }

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
