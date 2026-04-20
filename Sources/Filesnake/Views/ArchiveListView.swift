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

    func makeNSView(context: Context) -> DropScrollView {
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

        // DropScrollView owns the drag-and-drop — it IS the NSDraggingDestination
        let scroll = DropScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        context.coordinator.scrollView = scroll
        scroll.coordinator = context.coordinator
        return scroll
    }

    func updateNSView(_ scrollView: DropScrollView, context: Context) {
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
        scrollView.coordinator = coord

        if needsReload {
            table.reloadData()
            updateSortIndicators(table: table, key: document.sortKey, ascending: document.sortAscending)
        }
    }

    private func updateSortIndicators(
        table: NSTableView,
        key: ArchiveDocument.SortKey,
        ascending: Bool
    ) {
        let activeID: String
        switch key {
        case .name:       activeID = "name"
        case .size:       activeID = "size"
        case .compressed: activeID = "compressed"
        case .modified:   activeID = "modified"
        }
        let upArrow   = NSImage(systemSymbolName: "chevron.up",   accessibilityDescription: nil)
        let downArrow = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        for col in table.tableColumns {
            if col.identifier.rawValue == activeID {
                table.setIndicatorImage(ascending ? upArrow : downArrow, in: col)
                table.highlightedTableColumn = col
            } else {
                table.setIndicatorImage(nil, in: col)
            }
        }
    }
}

// MARK: - DropScrollView  (the real NSDraggingDestination)

final class DropScrollView: NSScrollView {
    /// Set by the representable so we can call back into SwiftUI state.
    weak var coordinator: Coordinator?

    private var dropOverlay: DropOverlayView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isArchiveDrag(sender) else { return [] }
        showOverlay(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isArchiveDrag(sender) else { showOverlay(false); return [] }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        showOverlay(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isArchiveDrag(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        showOverlay(false)
        guard let urls = sender.draggingPasteboard
                .readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              let first = urls.first(where: { ArchiveFormat.detect(url: $0) != nil })
        else { return false }
        // Dispatch to main to avoid calling into SwiftUI mid-drag
        DispatchQueue.main.async { [weak self] in
            self?.coordinator?.document?.open(url: first)
        }
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        showOverlay(false)
    }

    // MARK: Helpers

    private func isArchiveDrag(_ info: NSDraggingInfo) -> Bool {
        guard let urls = info.draggingPasteboard
            .readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        else { return false }
        return urls.contains { ArchiveFormat.detect(url: $0) != nil }
    }

    private func showOverlay(_ show: Bool) {
        if show {
            guard dropOverlay == nil else { return }
            let overlay = DropOverlayView(frame: bounds)
            overlay.autoresizingMask = [.width, .height]
            addSubview(overlay)
            dropOverlay = overlay
        } else {
            dropOverlay?.removeFromSuperview()
            dropOverlay = nil
        }
    }
}

// MARK: - Drop overlay view

final class DropOverlayView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 3
        layer?.cornerRadius = 10

        let label = NSTextField(labelWithString: "Release to Open Archive")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textColor = NSColor.controlAccentColor
        label.alignment = .center
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    // Block mouse events so the table underneath doesn't react while overlay is visible
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
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
    var sortKey: ArchiveDocument.SortKey = .name
    var sortAscending: Bool = true
    weak var table: FilesnakeTableView?
    weak var scrollView: DropScrollView?

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
            if entry.isDirectory {
                let total = document?.folderSize(for: entry) ?? 0
                return secondaryLabel(total > 0 ? Formatters.bytes(total) : "\u{2014}")
            }
            return secondaryLabel(Formatters.bytes(entry.uncompressedSize))

        case "compressed":
            if entry.isDirectory {
                let total = document?.folderCompressedSize(for: entry) ?? 0
                return secondaryLabel(total > 0 ? Formatters.bytes(total) : "\u{2014}")
            }
            return secondaryLabel(Formatters.bytes(entry.compressedSize))

        case "modified":
            return secondaryLabel(Formatters.date(entry.modified))

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

    // MARK: Selection

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        let idx = table.selectedRow
        document?.focused = (idx >= 0 && idx < entries.count) ? entries[idx].id : nil
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
                action: #selector(menuToggleCheck(_:)), keyEquivalent: ""
            )
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
            menu.addItem(oi)
            menu.addItem(.separator())
        }

        let ec = NSMenuItem(title: "Extract Checked\u{2026}",
            action: doc.checked.isEmpty ? nil : #selector(menuExtractChecked(_:)), keyEquivalent: "")
        ec.target = self; ec.isEnabled = !doc.checked.isEmpty
        menu.addItem(ec)

        let hasFiles = targetEntries.contains { !$0.isDirectory }

        let es = NSMenuItem(title: "Extract Selection\u{2026}",
            action: hasFiles ? #selector(menuExtractSelection(_:)) : nil, keyEquivalent: "")
        es.representedObject = targetIDs as NSArray; es.target = self; es.isEnabled = hasFiles
        menu.addItem(es)

        let eh = NSMenuItem(title: "Extract Selection Here",
            action: hasFiles ? #selector(menuExtractHere(_:)) : nil, keyEquivalent: "")
        eh.representedObject = targetIDs as NSArray; eh.target = self; eh.isEnabled = hasFiles
        menu.addItem(eh)

        if doc.format?.supportsDeletion == true {
            menu.addItem(.separator())
            let di = NSMenuItem(title: "Delete Checked from Archive",
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

    private func secondaryLabel(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        f.textColor = .secondaryLabelColor
        f.lineBreakMode = .byTruncatingTail
        return f
    }
}
