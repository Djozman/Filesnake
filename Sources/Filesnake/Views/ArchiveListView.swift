import SwiftUI
import AppKit

// MARK: - SwiftUI wrapper

struct ArchiveListView: View {
    @EnvironmentObject var document: ArchiveDocument
    var body: some View {
        ArchiveNSTableBridge()
    }
}

// MARK: - NSViewRepresentable

struct ArchiveNSTableBridge: NSViewRepresentable {
    @EnvironmentObject var document: ArchiveDocument

    func makeCoordinator() -> Coordinator { Coordinator() }

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
        // Right-click menu
        table.menu = NSMenu()
        table.menu?.delegate = context.coordinator

        let checkCol = NSTableColumn(identifier: .init("check"))
        checkCol.title = ""; checkCol.width = 28; checkCol.minWidth = 28; checkCol.maxWidth = 28
        checkCol.isEditable = false
        table.addTableColumn(checkCol)

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "Name"; nameCol.minWidth = 120; nameCol.isEditable = false
        table.addTableColumn(nameCol)

        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.title = "Size"; sizeCol.width = 80; sizeCol.minWidth = 60; sizeCol.maxWidth = 140
        sizeCol.isEditable = false
        table.addTableColumn(sizeCol)

        let compCol = NSTableColumn(identifier: .init("compressed"))
        compCol.title = "Compressed"; compCol.width = 90; compCol.minWidth = 70; compCol.maxWidth = 140
        compCol.isEditable = false
        table.addTableColumn(compCol)

        let modCol = NSTableColumn(identifier: .init("modified"))
        modCol.title = "Modified"; modCol.width = 140; modCol.minWidth = 100; modCol.maxWidth = 200
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
        if needsReload { table.reloadData() }
    }
}

// MARK: - Custom NSTableView

final class FilesnakeTableView: NSTableView {
    override func mouseDown(with event: NSEvent) {
        let col = self.column(at: convert(event.locationInWindow, from: nil))
        if col == 0 { super.mouseDown(with: event); return }
        super.mouseDown(with: event)
    }
}

// MARK: - Coordinator

@MainActor
final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var entries: [ArchiveEntry] = []
    var checkedSnapshot: Set<ArchiveEntry.ID> = []
    var document: ArchiveDocument?
    weak var table: FilesnakeTableView?

    // MARK: DataSource

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
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

    // MARK: Delegate

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        let idx = table.selectedRow
        document?.focused = (idx >= 0 && idx < entries.count) ? entries[idx].id : nil
    }

    // MARK: NSMenuDelegate — build menu just before it shows

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let table, let doc = document else { return }

        // Determine the target rows: selected rows, or the right-clicked row if nothing selected
        var targetRows = IndexSet(table.selectedRowIndexes)
        let clickedRow = table.clickedRow
        if clickedRow >= 0 {
            if !targetRows.contains(clickedRow) {
                // Right-clicked on an unselected row — select just that row
                table.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
                targetRows = IndexSet(integer: clickedRow)
            }
        }
        guard !targetRows.isEmpty else { return }

        let targetEntries = targetRows.compactMap { $0 < entries.count ? entries[$0] : nil }
        let targetIDs = targetEntries.map(\.id)
        let allChecked = targetIDs.allSatisfy { doc.checked.contains($0) }
        let noneChecked = targetIDs.allSatisfy { !doc.checked.contains($0) }
        let count = targetEntries.count
        let label = count == 1 ? "\"\(targetEntries[0].name)\"" : "\(count) items"

        // Check / Uncheck
        let checkItem = NSMenuItem(
            title: allChecked ? "Uncheck \(label)" : "Check \(label)",
            action: #selector(menuToggleCheck(_:)),
            keyEquivalent: ""
        )
        checkItem.representedObject = targetIDs as NSArray
        checkItem.target = self
        menu.addItem(checkItem)

        if !allChecked && !noneChecked {
            // Mixed state — offer both
            let checkAllItem = NSMenuItem(
                title: "Check \(label)",
                action: #selector(menuCheckAll(_:)),
                keyEquivalent: ""
            )
            checkAllItem.representedObject = targetIDs as NSArray
            checkAllItem.target = self

            let uncheckAllItem = NSMenuItem(
                title: "Uncheck \(label)",
                action: #selector(menuUncheckAll(_:)),
                keyEquivalent: ""
            )
            uncheckAllItem.representedObject = targetIDs as NSArray
            uncheckAllItem.target = self

            menu.removeAllItems()
            menu.addItem(checkAllItem)
            menu.addItem(uncheckAllItem)
        }

        menu.addItem(.separator())

        // Open folder (only when single directory)
        if count == 1, let folder = targetEntries.first, folder.isDirectory {
            let openItem = NSMenuItem(
                title: "Open Folder",
                action: #selector(menuOpenFolder(_:)),
                keyEquivalent: ""
            )
            openItem.representedObject = folder
            openItem.target = self
            menu.addItem(openItem)
            menu.addItem(.separator())
        }

        // Extract checked (global)
        let extractCheckedItem = NSMenuItem(
            title: "Extract Checked\u{2026}",
            action: doc.checked.isEmpty ? nil : #selector(menuExtractChecked(_:)),
            keyEquivalent: ""
        )
        extractCheckedItem.target = self
        extractCheckedItem.isEnabled = !doc.checked.isEmpty
        menu.addItem(extractCheckedItem)

        // Extract selection
        let hasFiles = targetEntries.contains { !$0.isDirectory }
        let extractSelectionItem = NSMenuItem(
            title: "Extract Selection\u{2026}",
            action: hasFiles ? #selector(menuExtractSelection(_:)) : nil,
            keyEquivalent: ""
        )
        extractSelectionItem.representedObject = targetIDs as NSArray
        extractSelectionItem.target = self
        extractSelectionItem.isEnabled = hasFiles
        menu.addItem(extractSelectionItem)

        // Extract here (next to archive file)
        let extractHereItem = NSMenuItem(
            title: "Extract Selection Here",
            action: hasFiles ? #selector(menuExtractHere(_:)) : nil,
            keyEquivalent: ""
        )
        extractHereItem.representedObject = targetIDs as NSArray
        extractHereItem.target = self
        extractHereItem.isEnabled = hasFiles
        menu.addItem(extractHereItem)

        // Delete (only for formats that support it)
        if doc.format?.supportsDeletion == true {
            menu.addItem(.separator())
            let deleteItem = NSMenuItem(
                title: "Delete Checked from Archive",
                action: doc.checked.isEmpty ? nil : #selector(menuDeleteChecked(_:)),
                keyEquivalent: ""
            )
            deleteItem.target = self
            deleteItem.isEnabled = !doc.checked.isEmpty
            deleteItem.attributedTitle = NSAttributedString(
                string: "Delete Checked from Archive",
                attributes: [.foregroundColor: NSColor.systemRed]
            )
            menu.addItem(deleteItem)
        }
    }

    // MARK: Menu actions

    @objc func menuToggleCheck(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? NSArray else { return }
        for case let id as ArchiveEntry.ID in ids { document?.toggleChecked(id) }
        table?.reloadData()
    }

    @objc func menuCheckAll(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? NSArray else { return }
        for case let id as ArchiveEntry.ID in ids { document?.checked.insert(id) }
        table?.reloadData()
    }

    @objc func menuUncheckAll(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? NSArray else { return }
        for case let id as ArchiveEntry.ID in ids { document?.checked.remove(id) }
        table?.reloadData()
    }

    @objc func menuOpenFolder(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ArchiveEntry else { return }
        document?.enterFolder(entry)
    }

    @objc func menuExtractChecked(_ sender: NSMenuItem) {
        document?.extractSelection()
    }

    @objc func menuExtractSelection(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? NSArray, let doc = document else { return }
        let paths = ids.compactMap { id -> String? in
            guard let eid = id as? ArchiveEntry.ID,
                  let entry = entries.first(where: { $0.id == eid }),
                  !entry.isDirectory else { return nil }
            return entry.path
        }
        guard !paths.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Extract Here"
        panel.message = "Choose destination folder"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        doc.extractPaths(paths, to: dest)
    }

    @objc func menuExtractHere(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? NSArray, let doc = document else { return }
        guard let archiveURL = doc.archiveURL else { return }
        let dest = archiveURL.deletingLastPathComponent()
        let paths = ids.compactMap { id -> String? in
            guard let eid = id as? ArchiveEntry.ID,
                  let entry = entries.first(where: { $0.id == eid }),
                  !entry.isDirectory else { return nil }
            return entry.path
        }
        guard !paths.isEmpty else { return }
        doc.extractPaths(paths, to: dest)
    }

    @objc func menuDeleteChecked(_ sender: NSMenuItem) {
        document?.deleteSelection()
    }

    // MARK: Row actions

    @objc func rowDoubleClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0, row < entries.count else { return }
        let entry = entries[row]
        if entry.isDirectory { document?.enterFolder(entry) }
    }

    @objc func checkboxClicked(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < entries.count else { return }
        document?.toggleChecked(entries[row].id)
    }

    // MARK: Cell builders

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
