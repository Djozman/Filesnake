import SwiftUI
import AppKit

struct ArchiveListView: View {
    @EnvironmentObject var document: ArchiveDocument

    var body: some View {
        ArchiveTableView()
            .contextMenu(forSelectionType: ArchiveEntry.ID.self) { ids in
                Button("Check") { ids.forEach { document.checked.insert($0) } }
                Button("Uncheck") { ids.forEach { document.checked.remove($0) } }
                Divider()
                if ids.count == 1,
                   let id = ids.first,
                   let folder = document.filteredEntries.first(where: { $0.id == id && $0.isDirectory }) {
                    Button("Open Folder") { document.enterFolder(folder) }
                    Divider()
                }
                Button("Extract Checked\u{2026}") { document.extractSelection() }
                    .disabled(document.checked.isEmpty)
                if document.format?.supportsDeletion == true {
                    Divider()
                    Button("Delete Checked from Archive", role: .destructive) { document.deleteSelection() }
                        .disabled(document.checked.isEmpty)
                }
            }
    }
}

// NSTableView wrapper — gives us proper multi-selection (drag, Cmd+click, Shift+click)
// without SwiftUI's Table fighting our checkboxes for the selection model.
struct ArchiveTableView: NSViewRepresentable {
    @EnvironmentObject var document: ArchiveDocument

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnSelection = false
        table.style = .inset
        table.rowHeight = 22
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))

        let checkCol = NSTableColumn(identifier: .init("check"))
        checkCol.title = ""
        checkCol.width = 24
        checkCol.minWidth = 24
        checkCol.maxWidth = 24
        table.addTableColumn(checkCol)

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "Name"
        nameCol.minWidth = 120
        table.addTableColumn(nameCol)

        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.title = "Size"
        sizeCol.width = 80
        sizeCol.minWidth = 60
        sizeCol.maxWidth = 140
        table.addTableColumn(sizeCol)

        let compCol = NSTableColumn(identifier: .init("compressed"))
        compCol.title = "Compressed"
        compCol.width = 90
        compCol.minWidth = 70
        compCol.maxWidth = 140
        table.addTableColumn(compCol)

        let modCol = NSTableColumn(identifier: .init("modified"))
        modCol.title = "Modified"
        modCol.width = 140
        modCol.minWidth = 100
        modCol.maxWidth = 200
        table.addTableColumn(modCol)

        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let table = scroll.documentView as! NSTableView
        context.coordinator.entries = document.filteredEntries
        context.coordinator.document = document
        table.reloadData()

        // Sync focused row
        if let focused = document.focused,
           let idx = document.filteredEntries.firstIndex(where: { $0.id == focused }) {
            if !table.selectedRowIndexes.contains(idx) {
                table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            }
        } else if document.focused == nil && !table.selectedRowIndexes.isEmpty {
            // Don't force-deselect; let user keep visual selection
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var entries: [ArchiveEntry] = []
        var document: ArchiveDocument?
        weak var table: NSTableView?

        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < entries.count else { return nil }
            let entry = entries[row]
            let id = tableColumn?.identifier.rawValue ?? ""

            switch id {
            case "check":
                let cell = tableView.makeView(withIdentifier: .init("checkCell"), owner: nil) as? NSButton
                    ?? makeCheckbox()
                cell.state = (document?.checked.contains(entry.id) == true) ? .on : .off
                cell.tag = row
                cell.action = #selector(checkboxToggled(_:))
                cell.target = self
                return cell

            case "name":
                let cell = tableView.makeView(withIdentifier: .init("nameCell"), owner: nil) as? NSTableCellView
                    ?? NSTableCellView()
                cell.identifier = .init("nameCell")
                cell.textField?.stringValue = entry.name
                cell.imageView?.image = FileIcon.icon(for: entry)
                return cell

            case "size":
                return makeLabel(entry.isDirectory ? "\u{2014}" : Formatters.bytes(entry.uncompressedSize))

            case "compressed":
                return makeLabel(entry.isDirectory ? "\u{2014}" : Formatters.bytes(entry.compressedSize))

            case "modified":
                return makeLabel(Formatters.date(entry.modified))

            default:
                return nil
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            let idx = table.selectedRow
            guard idx >= 0, idx < entries.count else {
                document?.focused = nil
                return
            }
            document?.focused = entries[idx].id
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < entries.count else { return }
            let entry = entries[row]
            if entry.isDirectory {
                document?.enterFolder(entry)
            }
        }

        @objc func checkboxToggled(_ sender: NSButton) {
            let row = sender.tag
            guard row >= 0, row < entries.count else { return }
            let id = entries[row].id
            document?.toggleChecked(id)
        }

        private func makeCheckbox() -> NSButton {
            let btn = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxToggled(_:)))
            btn.identifier = .init("checkCell")
            return btn
        }

        private func makeLabel(_ text: String) -> NSTextField {
            let f = NSTextField(labelWithString: text)
            f.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            f.textColor = .secondaryLabelColor
            f.lineBreakMode = .byTruncatingMiddle
            return f
        }
    }
}
