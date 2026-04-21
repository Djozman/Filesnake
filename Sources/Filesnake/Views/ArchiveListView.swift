import SwiftUI
import AppKit

// MARK: - SwiftUI wrapper

struct ArchiveListView: View {
    @EnvironmentObject var document: ArchiveDocument
    var body: some View {
        ArchiveNSTableBridge()
    }
}

// MARK: - NSScrollView that refuses first responder (lets search field keep it)

final class NonFocusableScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { false }
    override func becomeFirstResponder() -> Bool { false }
}

// MARK: - NSTableView with full row interaction

final class FilesnakeTableView: NSTableView {
    override func mouseDown(with event: NSEvent) { super.mouseDown(with: event) }
}

// MARK: - Custom row view with blue (accent) selection highlight

final class AccentRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        // Fill the full row with accent color (no vertical gap)
        let color = NSColor.controlAccentColor
        color.setFill()
        let selRect = bounds
        let path = NSBezierPath(rect: selRect)
        path.fill()

        // Thin white separator at the bottom between stacked selections
        NSColor.white.withAlphaComponent(0.15).setFill()
        NSRect(x: selRect.minX, y: bounds.maxY - 0.5, width: selRect.width, height: 0.5).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        return isSelected ? .emphasized : .normal
    }
}

// MARK: - Centered cell view (reusable)

final class CenteredTableCellView: NSTableCellView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let tf = NSTextField(labelWithString: "")
        tf.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        tf.textColor = .secondaryLabelColor
        tf.lineBreakMode = .byTruncatingTail
        tf.alignment = .center
        tf.translatesAutoresizingMaskIntoConstraints = false
        textField = tf
        addSubview(tf)
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: leadingAnchor),
            tf.trailingAnchor.constraint(equalTo: trailingAnchor),
            tf.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - NSViewRepresentable

struct ArchiveNSTableBridge: NSViewRepresentable {
    @EnvironmentObject var document: ArchiveDocument

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NonFocusableScrollView {
        let table = FilesnakeTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnSelection = false
        table.allowsColumnReordering = false
        table.style = .fullWidth
        table.rowHeight = 22
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.doubleAction = #selector(Coordinator.rowDoubleClicked(_:))
        table.target = context.coordinator
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
        sizeCol.headerCell.alignment = .center
        table.addTableColumn(sizeCol)

        let compCol = NSTableColumn(identifier: .init("compressed"))
        compCol.title = "Compressed"; compCol.width = 90; compCol.minWidth = 70; compCol.maxWidth = 140
        compCol.isEditable = false
        compCol.headerCell.alignment = .center
        table.addTableColumn(compCol)

        let modCol = NSTableColumn(identifier: .init("modified"))
        modCol.title = "Modified"; modCol.width = 140; modCol.minWidth = 100; modCol.maxWidth = 200
        modCol.isEditable = false
        modCol.headerCell.alignment = .center
        table.addTableColumn(modCol)

        context.coordinator.table = table

        let scroll = NonFocusableScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        context.coordinator.scrollView = scroll
        return scroll
    }

    func updateNSView(_ scrollView: NonFocusableScrollView, context: Context) {
        let coord = context.coordinator
        guard let table = scrollView.documentView as? FilesnakeTableView else { return }
        let newEntries = document.filteredEntries
        let needsReload = coord.entries.map(\.id) != newEntries.map(\.id)
            || coord.checkedSnapshot != document.checked
            || coord.sortKey != document.sortKey
            || coord.sortAscending != document.sortAscending

        coord.entries = newEntries
        coord.checkedSnapshot = document.checked
        coord.document = document
        coord.sortKey = document.sortKey
        coord.sortAscending = document.sortAscending
        if needsReload {
            table.reloadData()
            updateSortIndicators(table: table, key: document.sortKey, ascending: document.sortAscending)
        }
    }

    private func updateSortIndicators(table: NSTableView, key: ArchiveDocument.SortKey, ascending: Bool) {
        let activeID: String
        switch key {
        case .name:       activeID = "name"
        case .size:       activeID = "size"
        case .compressed: activeID = "compressed"
        case .modified:   activeID = "modified"
        }
        let up   = NSImage(systemSymbolName: "chevron.up",   accessibilityDescription: nil)
        let down = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        for col in table.tableColumns {
            if col.identifier.rawValue == activeID {
                table.setIndicatorImage(ascending ? up : down, in: col)
                table.highlightedTableColumn = col
            } else {
                table.setIndicatorImage(nil, in: col)
            }
        }
    }
}

// MARK: - Coordinator

@MainActor
final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {

    var entries: [ArchiveEntry] = []
    var checkedSnapshot: Set<ArchiveEntry.ID> = []
    var document: ArchiveDocument?
    var sortKey: ArchiveDocument.SortKey = .name
    var sortAscending: Bool = true
    weak var table: FilesnakeTableView?
    weak var scrollView: NonFocusableScrollView?

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
            let text: String
            if entry.isDirectory {
                let total = document?.folderSize(for: entry) ?? 0
                text = total > 0 ? Formatters.bytes(total) : "\u{2014}"
            } else {
                text = Formatters.bytes(entry.uncompressedSize)
            }
            return centeredCell(text, id: "SizeCell", in: tableView)

        case "compressed":
            let text: String
            if entry.isDirectory {
                let total = document?.folderCompressedSize(for: entry) ?? 0
                text = total > 0 ? Formatters.bytes(total) : "\u{2014}"
            } else {
                text = Formatters.bytes(entry.compressedSize)
            }
            return centeredCell(text, id: "CompCell", in: tableView)

        case "modified":
            return centeredCell(Formatters.date(entry.modified), id: "ModCell", in: tableView)

        default:
            return nil
        }
    }

    // MARK: Column header sort

    func tableView(_ tableView: NSTableView, mouseDownInHeaderOf tableColumn: NSTableColumn) {
        let key: ArchiveDocument.SortKey
        switch tableColumn.identifier.rawValue {
        case "name":       key = .name
        case "size":       key = .size
        case "compressed": key = .compressed
        case "modified":   key = .modified
        default: return
        }
        document?.toggleSort(key: key)
    }

    // MARK: Row view (blue highlight)

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        return AccentRowView()
    }

    // MARK: Selection

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let t = notification.object as? NSTableView else { return }
        let idx = t.selectedRow
        document?.focused = (idx >= 0 && idx < entries.count) ? entries[idx].id : nil
    }

    // MARK: Row actions

    @objc func rowDoubleClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0, row < entries.count else { return }
        if entries[row].isDirectory { document?.enterFolder(entries[row]) }
    }

    @objc func checkboxClicked(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < entries.count else { return }
        document?.toggleChecked(entries[row].id)
    }

    // MARK: Right-click menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let table, let doc = document else { return }

        var targetRows = IndexSet(table.selectedRowIndexes)
        let clickedRow = table.clickedRow
        if clickedRow >= 0, !targetRows.contains(clickedRow) {
            table.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            targetRows = IndexSet(integer: clickedRow)
        }
        guard !targetRows.isEmpty else { return }

        let targetEntries = targetRows.compactMap { $0 < entries.count ? entries[$0] : nil }
        let targetIDs = targetEntries.map(\.id)
        let allChecked = targetIDs.allSatisfy { doc.checked.contains($0) }
        let noneChecked = targetIDs.allSatisfy { !doc.checked.contains($0) }
        let count = targetEntries.count
        let label = count == 1 ? "\"\(targetEntries[0].name)\"" : "\(count) items"

        if allChecked || noneChecked {
            let item = NSMenuItem(
                title: allChecked ? "Uncheck \(label)" : "Check \(label)",
                action: #selector(menuToggleCheck(_:)), keyEquivalent: "")
            item.representedObject = targetIDs as NSArray; item.target = self
            menu.addItem(item)
        } else {
            let ci = NSMenuItem(title: "Check \(label)", action: #selector(menuCheckAll(_:)), keyEquivalent: "")
            ci.representedObject = targetIDs as NSArray; ci.target = self
            let ui = NSMenuItem(title: "Uncheck \(label)", action: #selector(menuUncheckAll(_:)), keyEquivalent: "")
            ui.representedObject = targetIDs as NSArray; ui.target = self
            menu.addItem(ci); menu.addItem(ui)
        }
        menu.addItem(.separator())
        if count == 1, let folder = targetEntries.first, folder.isDirectory {
            let oi = NSMenuItem(title: "Open Folder", action: #selector(menuOpenFolder(_:)), keyEquivalent: "")
            oi.representedObject = folder; oi.target = self
            menu.addItem(oi); menu.addItem(.separator())
        }
        let ec = NSMenuItem(
            title: "Extract Checked\u{2026}",
            action: doc.checked.isEmpty ? nil : #selector(menuExtractChecked(_:)), keyEquivalent: "")
        ec.target = self; ec.isEnabled = !doc.checked.isEmpty
        menu.addItem(ec)
        let hasFiles = targetEntries.contains { !$0.isDirectory }
        let es = NSMenuItem(
            title: "Extract Selection\u{2026}",
            action: hasFiles ? #selector(menuExtractSelection(_:)) : nil, keyEquivalent: "")
        es.representedObject = targetIDs as NSArray; es.target = self; es.isEnabled = hasFiles
        menu.addItem(es)
        let eh = NSMenuItem(
            title: "Extract Selection Here",
            action: hasFiles ? #selector(menuExtractHere(_:)) : nil, keyEquivalent: "")
        eh.representedObject = targetIDs as NSArray; eh.target = self; eh.isEnabled = hasFiles
        menu.addItem(eh)
        if doc.format?.supportsDeletion == true {
            menu.addItem(.separator())
            let di = NSMenuItem(
                title: "Delete Checked from Archive",
                action: doc.checked.isEmpty ? nil : #selector(menuDeleteChecked(_:)), keyEquivalent: "")
            di.target = self; di.isEnabled = !doc.checked.isEmpty
            di.attributedTitle = NSAttributedString(
                string: "Delete Checked from Archive",
                attributes: [.foregroundColor: NSColor.systemRed])
            menu.addItem(di)
        }
    }

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
    @objc func menuExtractChecked(_ sender: NSMenuItem) { document?.extractSelection() }
    @objc func menuExtractSelection(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? NSArray, let doc = document else { return }
        let paths = ids.compactMap { id -> String? in
            guard let eid = id as? ArchiveEntry.ID,
                  let e = entries.first(where: { $0.id == eid }), !e.isDirectory else { return nil }
            return e.path
        }
        guard !paths.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Extract Here"; panel.message = "Choose destination folder"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        doc.extractPaths(paths, to: dest)
    }
    @objc func menuExtractHere(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? NSArray, let doc = document,
              let archiveURL = doc.archiveURL else { return }
        let dest = archiveURL.deletingLastPathComponent()
        let paths = ids.compactMap { id -> String? in
            guard let eid = id as? ArchiveEntry.ID,
                  let e = entries.first(where: { $0.id == eid }), !e.isDirectory else { return nil }
            return e.path
        }
        guard !paths.isEmpty else { return }
        doc.extractPaths(paths, to: dest)
    }
    @objc func menuDeleteChecked(_ sender: NSMenuItem) { document?.deleteSelection() }

    // MARK: Cell builders

    private func makeNameCell() -> NSTableCellView {
        let cell = NSTableCellView()
        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.imageScaling = .scaleProportionallyDown
        cell.imageView = iv; cell.addSubview(iv)
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingMiddle
        cell.textField = tf; cell.addSubview(tf)
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 16),
            iv.heightAnchor.constraint(equalToConstant: 16),
            tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 5),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func centeredCell(_ text: String, id: String, in tableView: NSTableView) -> NSTableCellView {
        let cellID = NSUserInterfaceItemIdentifier(id)
        let cell: CenteredTableCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? CenteredTableCellView {
            cell = reused
        } else {
            cell = CenteredTableCellView()
            cell.identifier = cellID
        }
        cell.textField?.stringValue = text
        return cell
    }
}
