import SwiftUI
import AppKit

// MARK: - SwiftUI wrapper

struct ArchiveListView: View {
    @EnvironmentObject var document: ArchiveDocument

    var body: some View {
        ArchiveNSTableBridge()
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

// MARK: - NSViewRepresentable

struct ArchiveNSTableBridge: NSViewRepresentable {
    @EnvironmentObject var document: ArchiveDocument

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FilesnakeTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnSelection = false
        table.allowsColumnReordering = false
        table.style = .inset
        table.rowHeight = 22
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.doubleAction = #selector(Coordinator.rowDoubleClicked(_:))
        table.target = context.coordinator

        let checkCol = NSTableColumn(identifier: .init("check"))
        checkCol.title = ""
        checkCol.width = 28; checkCol.minWidth = 28; checkCol.maxWidth = 28
        checkCol.isEditable = false
        table.addTableColumn(checkCol)

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "Name"
        nameCol.minWidth = 120
        nameCol.isEditable = false
        table.addTableColumn(nameCol)

        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.title = "Size"
        sizeCol.width = 80; sizeCol.minWidth = 60; sizeCol.maxWidth = 140
        sizeCol.isEditable = false
        table.addTableColumn(sizeCol)

        let compCol = NSTableColumn(identifier: .init("compressed"))
        compCol.title = "Compressed"
        compCol.width = 90; compCol.minWidth = 70; compCol.maxWidth = 140
        compCol.isEditable = false
        table.addTableColumn(compCol)

        let modCol = NSTableColumn(identifier: .init("modified"))
        modCol.title = "Modified"
        modCol.width = 140; modCol.minWidth = 100; modCol.maxWidth = 200
        modCol.isEditable = false
        table.addTableColumn(modCol)

        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coord = context.coordinator
        let table = scrollView.documentView as! FilesnakeTableView

        let newEntries = document.filteredEntries
        let needsReload = coord.entries.map(\.id) != newEntries.map(\.id)
            || coord.checkedSnapshot != document.checked

        coord.entries = newEntries
        coord.checkedSnapshot = document.checked
        coord.document = document

        if needsReload {
            table.reloadData()
        }
    }
}

// MARK: - Custom NSTableView

final class FilesnakeTableView: NSTableView {
    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let col = self.column(at: localPoint)
        // checkbox column: let the button handle it, skip selection logic
        if col == 0 {
            super.mouseDown(with: event)
            return
        }
        super.mouseDown(with: event)
    }
}

// MARK: - Coordinator

@MainActor
final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var entries: [ArchiveEntry] = []
    var checkedSnapshot: Set<ArchiveEntry.ID> = []
    var document: ArchiveDocument?
    weak var table: FilesnakeTableView?

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let entry = entries[row]

        switch tableColumn?.identifier.rawValue {
        case "check":
            let cellID = NSUserInterfaceItemIdentifier("CheckCell")
            let btn: NSButton
            if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSButton {
                btn = reused
            } else {
                btn = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxClicked(_:)))
                btn.identifier = cellID
                btn.refusesFirstResponder = true
            }
            btn.state = checkedSnapshot.contains(entry.id) ? .on : .off
            btn.tag = row
            btn.action = #selector(checkboxClicked(_:))
            btn.target = self
            return btn

        case "name":
            let cellID = NSUserInterfaceItemIdentifier("NameCell")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = makeNameCell()
                cell.identifier = cellID
            }
            cell.imageView?.image = FileIcon.icon(for: entry)
            cell.textField?.stringValue = entry.isDirectory ? entry.name + "  \u{203a}" : entry.name
            cell.textField?.textColor = .labelColor
            return cell

        case "size":
            return secondaryLabel(entry.isDirectory ? "\u{2014}" : Formatters.bytes(entry.uncompressedSize))

        case "compressed":
            return secondaryLabel(entry.isDirectory ? "\u{2014}" : Formatters.bytes(entry.compressedSize))

        case "modified":
            return secondaryLabel(Formatters.date(entry.modified))

        default:
            return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        let idx = table.selectedRow
        if idx >= 0, idx < entries.count {
            document?.focused = entries[idx].id
        } else {
            document?.focused = nil
        }
    }

    @objc func rowDoubleClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0, row < entries.count else { return }
        let entry = entries[row]
        if entry.isDirectory {
            document?.enterFolder(entry)
        }
    }

    @objc func checkboxClicked(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < entries.count else { return }
        document?.toggleChecked(entries[row].id)
    }

    private func makeNameCell() -> NSTableCellView {
        let cell = NSTableCellView()

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        cell.imageView = imageView
        cell.addSubview(imageView)

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingMiddle
        cell.textField = textField
        cell.addSubview(textField)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 5),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func secondaryLabel(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        f.textColor = .secondaryLabelColor
        f.lineBreakMode = .byTruncatingTail
        return f
    }
}
