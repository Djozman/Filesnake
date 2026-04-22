import SwiftUI
import AppKit
import Combine

// MARK: - SwiftUI wrapper

struct ArchiveListView: View {
    @EnvironmentObject var document: ArchiveDocument
    var body: some View {
        ArchiveNSTableBridge(document: document)
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

// MARK: - Name cell with disclosure triangle + indent

final class NameCellView: NSTableCellView {
    /// Closure invoked when the disclosure triangle is clicked.
    var onToggleExpand: (() -> Void)?
    /// Closure invoked when inline rename editing ends with the new name.
    var onRenameCompleted: ((String) -> Void)?
    /// The entry ID this cell currently represents (for rename tracking).
    var entryID: ArchiveEntry.ID?

    private let disclosure = NSButton()
    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private var leadingConstraint: NSLayoutConstraint!
    private var renameOriginalName: String = ""
    private var isRenaming: Bool = false

    private static let indentPerLevel: CGFloat = 14
    private static let disclosureSize: CGFloat = 14
    private static let baseLeading: CGFloat = 2

    override init(frame: NSRect) {
        super.init(frame: frame)

        // Disclosure button (chevron that flips on expansion)
        disclosure.isBordered = false
        disclosure.bezelStyle = .regularSquare
        disclosure.imagePosition = .imageOnly
        disclosure.imageScaling = .scaleProportionallyDown
        disclosure.refusesFirstResponder = true
        disclosure.target = self
        disclosure.action = #selector(disclosureClicked)
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        // Subtle styling — muted color, small size — so it doesn't fight the row
        disclosure.contentTintColor = .secondaryLabelColor
        addSubview(disclosure)

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        imageView = iconView
        addSubview(iconView)

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.isEditable = true
        nameField.isSelectable = true
        nameField.focusRingType = .none
        nameField.delegate = self
        textField = nameField
        addSubview(nameField)

        leadingConstraint = disclosure.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: Self.baseLeading)

        NSLayoutConstraint.activate([
            leadingConstraint,
            disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: Self.disclosureSize),
            disclosure.heightAnchor.constraint(equalToConstant: Self.disclosureSize),

            iconView.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            nameField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func disclosureClicked() { onToggleExpand?() }

    func configure(depth: Int,
                   isDirectory: Bool,
                   isExpanded: Bool,
                   icon: NSImage?,
                   name: String,
                   entryID: ArchiveEntry.ID? = nil) {
        leadingConstraint.constant = Self.baseLeading + CGFloat(depth) * Self.indentPerLevel
        iconView.image = icon
        nameField.stringValue = name
        nameField.textColor = .labelColor
        nameField.isEditable = false // Only enable when rename is triggered
        renameOriginalName = name
        isRenaming = false
        self.entryID = entryID

        if isDirectory {
            let symbol = isExpanded ? "chevron.down" : "chevron.right"
            let a11y = isExpanded ? "Collapse" : "Expand"
            disclosure.image = NSImage(systemSymbolName: symbol, accessibilityDescription: a11y)
            disclosure.toolTip = isExpanded ? "Collapse" : "Expand"
            disclosure.isHidden = false
            disclosure.isEnabled = true
        } else {
            disclosure.image = nil
            disclosure.toolTip = nil
            disclosure.isHidden = true
            disclosure.isEnabled = false
        }
    }

    /// Programmatically start inline editing of the name field.
    func beginRename() {
        renameOriginalName = nameField.stringValue
        isRenaming = true
        nameField.isEditable = true
        nameField.isSelectable = true
        window?.makeFirstResponder(nameField)
        // Select just the filename stem (before the last dot)
        if let editor = nameField.currentEditor() {
            let name = nameField.stringValue
            if let dotRange = name.range(of: ".", options: .backwards),
               dotRange.lowerBound != name.startIndex {
                let stemLength = name.distance(from: name.startIndex, to: dotRange.lowerBound)
                editor.selectedRange = NSRange(location: 0, length: stemLength)
            } else {
                editor.selectAll(nil)
            }
        }
    }
}

extension NameCellView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard isRenaming else { return }
        isRenaming = false
        let newName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        nameField.isEditable = false
        guard !newName.isEmpty, newName != renameOriginalName else { return }
        // Defer model mutation until AppKit has fully finished edit teardown.
        DispatchQueue.main.async { [weak self] in
            self?.onRenameCompleted?(newName)
        }
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
    // NOT @EnvironmentObject — we pass this as a plain, unobserved reference
    // so that @Published changes do NOT trigger SwiftUI's layout cycle.
    let document: ArchiveDocument

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
        
        table.setDraggingSourceOperationMask(.copy, forLocal: false)

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

        // Wire up the coordinator to observe the document via Combine
        // — completely outside SwiftUI's layout cycle.
        context.coordinator.bind(to: document)

        return scroll
    }

    func updateNSView(_ scrollView: NonFocusableScrollView, context: Context) {
        // If the document object itself changed (e.g. environment swap),
        // rebind. Otherwise this is a no-op — the Coordinator drives all
        // table updates via its own Combine subscription.
        if context.coordinator.document !== document {
            context.coordinator.bind(to: document)
        }
    }
}

// MARK: - Coordinator

@MainActor
final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {

    var rows: [ArchiveDocument.DisplayRow] = []
    var checkedSnapshot: Set<ArchiveEntry.ID> = []
    var expandedSnapshot: Set<String> = []
    var folderPathSnapshot: String = ""
    var searchSnapshot: String = ""
    var document: ArchiveDocument?
    var sortKey: ArchiveDocument.SortKey = .name
    var sortAscending: Bool = true
    weak var table: FilesnakeTableView?
    weak var scrollView: NonFocusableScrollView?
    private var cancellable: AnyCancellable?

    /// Subscribe to the document's objectWillChange via Combine.
    /// All table updates happen here — completely outside SwiftUI's layout cycle.
    func bind(to doc: ArchiveDocument) {
        document = doc
        // Seed initial state
        syncTable()
        // Subscribe: each @Published change fires objectWillChange,
        // we coalesce and sync on the next runloop tick.
        cancellable = doc.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncTable()
            }
    }

    /// Diff the document state vs our snapshots and update the table.
    private func syncTable() {
        guard let doc = document, let table else { return }

        let newRows = doc.filteredDisplayRows
        let oldRows = rows
        let oldExpanded = expandedSnapshot

        let rowIdsChanged = oldRows.map(\.id) != newRows.map(\.id)
        let depthsChanged = oldRows.map(\.depth) != newRows.map(\.depth)
        let checkedChanged = checkedSnapshot != doc.checked
        let expandedChanged = oldExpanded != doc.expandedFolders
        let sortChanged_ = sortKey != doc.sortKey || sortAscending != doc.sortAscending
        let folderPathChanged = folderPathSnapshot != doc.currentFolderPath
        let searchChanged = searchSnapshot != doc.searchText

        // Commit snapshots
        rows = newRows
        checkedSnapshot = doc.checked
        expandedSnapshot = doc.expandedFolders
        sortKey = doc.sortKey
        sortAscending = doc.sortAscending
        folderPathSnapshot = doc.currentFolderPath
        searchSnapshot = doc.searchText

        let onlyExpansionDelta = expandedChanged
            && !folderPathChanged && !searchChanged
            && !sortChanged_ && !checkedChanged && rowIdsChanged

        if onlyExpansionDelta {
            animateExpansionDiff(table: table, oldRows: oldRows, newRows: newRows,
                                oldExpanded: oldExpanded, newExpanded: doc.expandedFolders)
        } else if rowIdsChanged || depthsChanged || checkedChanged
                    || expandedChanged || sortChanged_ {
            table.reloadData()
            updateSortIndicators(table: table, key: doc.sortKey, ascending: doc.sortAscending)
        }
    }

    private func animateExpansionDiff(table: NSTableView,
                                      oldRows: [ArchiveDocument.DisplayRow],
                                      newRows: [ArchiveDocument.DisplayRow],
                                      oldExpanded: Set<String>,
                                      newExpanded: Set<String>) {
        let diff = newRows.map(\.id).difference(from: oldRows.map(\.id))
        var insertions = IndexSet()
        var removals = IndexSet()
        for change in diff {
            switch change {
            case .insert(let offset, _, _): insertions.insert(offset)
            case .remove(let offset, _, _): removals.insert(offset)
            }
        }
        let toggledPaths = oldExpanded.symmetricDifference(newExpanded)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.allowsImplicitAnimation = true
            table.beginUpdates()
            if !removals.isEmpty {
                table.removeRows(at: removals, withAnimation: [.slideUp, .effectFade])
            }
            if !insertions.isEmpty {
                table.insertRows(at: insertions, withAnimation: [.slideDown, .effectFade])
            }
            table.endUpdates()
        }

        if !toggledPaths.isEmpty {
            var parentRows = IndexSet()
            for (idx, row) in newRows.enumerated()
            where row.entry.isDirectory && toggledPaths.contains(row.entry.path) {
                parentRows.insert(idx)
            }
            if !parentRows.isEmpty {
                let colIdx = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
                if colIdx >= 0 {
                    table.reloadData(forRowIndexes: parentRows,
                                     columnIndexes: IndexSet(integer: colIdx))
                }
            }
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

    private func entry(at row: Int) -> ArchiveEntry? {
        guard row >= 0, row < rows.count else { return nil }
        return rows[row].entry
    }

    // MARK: DataSource

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let entry = entry(at: row) else { return nil }
        let fileType = "public.data" 
        let provider = NSFilePromiseProvider(fileType: fileType, delegate: self)
        provider.userInfo = ["entryID": entry.id]
        return provider
    }
    
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        session.enumerateDraggingItems(options: [], for: nil, classes: [NSFilePromiseProvider.self]) { draggingItem, idx, stop in
            if let provider = draggingItem.item as? NSFilePromiseProvider,
               let userInfo = provider.userInfo as? [String: Any],
               let entryID = userInfo["entryID"] as? ArchiveEntry.ID,
               let entry = self.document?.entries.first(where: { $0.id == entryID }) {
                
                let icon = FileIcon.icon(for: entry) ?? NSWorkspace.shared.icon(for: .data)
                
                let font = NSFont.systemFont(ofSize: 13, weight: .medium)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
                let str = NSAttributedString(string: entry.name, attributes: attrs)
                let textRect = str.boundingRect(with: NSSize(width: 250, height: CGFloat.greatestFiniteMagnitude), options: .usesLineFragmentOrigin)
                
                let padding: CGFloat = 6
                let iconSize: CGFloat = 24
                let imageSize = NSSize(width: padding + iconSize + padding + textRect.width + padding, height: max(iconSize + padding*2, textRect.height + padding*2))
                
                let dragImage = NSImage(size: imageSize)
                dragImage.lockFocus()
                
                let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: imageSize), xRadius: 8, yRadius: 8)
                NSColor.black.withAlphaComponent(0.6).setFill()
                path.fill()
                
                icon.draw(in: NSRect(x: padding, y: (imageSize.height - iconSize) / 2, width: iconSize, height: iconSize))
                str.draw(in: NSRect(x: padding + iconSize + padding, y: (imageSize.height - textRect.height) / 2, width: textRect.width, height: textRect.height))
                
                dragImage.unlockFocus()
                
                draggingItem.setDraggingFrame(NSRect(origin: draggingItem.draggingFrame.origin, size: imageSize), contents: dragImage)
            }
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let displayRow = rows[row]
        let entry = displayRow.entry
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
                btn.allowsMixedState = true
            }
            // Derived tri-state: folders inherit from their file descendants.
            switch document?.folderCheckState(entry) ?? .unchecked {
            case .unchecked: btn.state = .off
            case .mixed:     btn.state = .mixed
            case .checked:   btn.state = .on
            }
            btn.tag = row
            btn.action = #selector(checkboxClicked(_:))
            btn.target = self
            return btn

        case "name":
            let cellID = NSUserInterfaceItemIdentifier("NameRowCell")
            let cell: NameCellView
            if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NameCellView {
                cell = reused
            } else {
                cell = NameCellView()
                cell.identifier = cellID
            }
            let expanded = document?.isExpanded(entry) ?? false
            cell.configure(
                depth: displayRow.depth,
                isDirectory: entry.isDirectory,
                isExpanded: expanded,
                icon: FileIcon.icon(for: entry),
                name: entry.name,
                entryID: entry.id)
            cell.onToggleExpand = { [weak self] in
                self?.document?.toggleExpanded(entry)
            }
            cell.onRenameCompleted = { [weak self] newName in
                self?.document?.renameEntry(entry.id, newName: newName)
            }
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
        document?.focused = entry(at: idx)?.id
    }

    // MARK: Row actions

    @objc func rowDoubleClicked(_ sender: NSTableView) {
        guard let e = entry(at: sender.clickedRow) else { return }
        if e.isDirectory { document?.enterFolder(e) }
    }

    @objc func checkboxClicked(_ sender: NSButton) {
        guard let e = entry(at: sender.tag) else { return }
        document?.toggleChecked(e.id)
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

        let targetEntries = targetRows.compactMap { entry(at: $0) }
        let targetIDs = targetEntries.map(\.id)
        // Tri-state-aware: treat `.mixed` as "not fully checked" so clicking
        // toggles to fully checked.
        let allChecked = targetEntries.allSatisfy { doc.folderCheckState($0) == .checked }
        let noneChecked = targetEntries.allSatisfy { doc.folderCheckState($0) == .unchecked }
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

        // Open / Open With — only makes sense for a single entry.
        if count == 1, let solo = targetEntries.first {
            menu.addItem(.separator())
            let openTitle = solo.isDirectory ? "Open in Finder" : "Open"
            let oi = NSMenuItem(title: openTitle, action: #selector(menuOpen(_:)), keyEquivalent: "")
            oi.representedObject = solo; oi.target = self
            menu.addItem(oi)
            if !solo.isDirectory {
                let owi = NSMenuItem(title: "Open With\u{2026}",
                                     action: #selector(menuOpenWith(_:)), keyEquivalent: "")
                owi.representedObject = solo; owi.target = self
                menu.addItem(owi)
            }
            if solo.isDirectory {
                // Legacy: "enter" the folder (switch the middle pane into it).
                let enter = NSMenuItem(title: "Enter Folder",
                                       action: #selector(menuEnterFolder(_:)), keyEquivalent: "")
                enter.representedObject = solo; enter.target = self
                menu.addItem(enter)
            }

            // Rename (single item only, on mutable formats)
            if doc.format?.supportsRename == true {
                let ri = NSMenuItem(title: "Rename\u{2026}",
                                    action: #selector(menuRename(_:)), keyEquivalent: "")
                ri.representedObject = solo; ri.target = self
                menu.addItem(ri)
            }
        }

        menu.addItem(.separator())
        let ec = NSMenuItem(
            title: "Extract Checked\u{2026}",
            action: doc.checked.isEmpty ? nil : #selector(menuExtractChecked(_:)), keyEquivalent: "")
        ec.target = self; ec.isEnabled = !doc.checked.isEmpty
        menu.addItem(ec)
        let hasEntries = !targetEntries.isEmpty
        let es = NSMenuItem(
            title: "Extract Selection\u{2026}",
            action: hasEntries ? #selector(menuExtractSelection(_:)) : nil, keyEquivalent: "")
        es.representedObject = targetIDs as NSArray; es.target = self; es.isEnabled = hasEntries
        menu.addItem(es)
        let eh = NSMenuItem(
            title: "Extract Selection Here",
            action: hasEntries ? #selector(menuExtractHere(_:)) : nil, keyEquivalent: "")
        eh.representedObject = targetIDs as NSArray; eh.target = self; eh.isEnabled = hasEntries
        menu.addItem(eh)

        if doc.format?.supportsDeletion == true {
            menu.addItem(.separator())
            // Delete the currently right-clicked selection (files and/or folders).
            let ds = NSMenuItem(
                title: "Delete \(label) from Archive",
                action: hasEntries ? #selector(menuDeleteSelection(_:)) : nil, keyEquivalent: "")
            ds.representedObject = targetIDs as NSArray; ds.target = self
            ds.isEnabled = hasEntries
            ds.attributedTitle = NSAttributedString(
                string: "Delete \(label) from Archive",
                attributes: [.foregroundColor: NSColor.systemRed])
            menu.addItem(ds)

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
        guard let ids = sender.representedObject as? NSArray, let doc = document else { return }
        let idList = ids.compactMap { $0 as? ArchiveEntry.ID }
        // Tri-state-aware: fully-checked → uncheck, otherwise → check.
        let allChecked = idList.allSatisfy { id in
            guard let e = doc.entries.first(where: { $0.id == id }) else { return false }
            return doc.folderCheckState(e) == .checked
        }
        doc.setChecked(!allChecked, forIDs: idList)
        // No reloadData here — @Published `checked` triggers updateNSView.
    }
    @objc func menuCheckAll(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? NSArray else { return }
        let idList = ids.compactMap { $0 as? ArchiveEntry.ID }
        document?.setChecked(true, forIDs: idList)
    }
    @objc func menuUncheckAll(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? NSArray else { return }
        let idList = ids.compactMap { $0 as? ArchiveEntry.ID }
        document?.setChecked(false, forIDs: idList)
    }
    @objc func menuEnterFolder(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ArchiveEntry else { return }
        document?.enterFolder(entry)
    }
    @objc func menuOpen(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ArchiveEntry else { return }
        document?.openEntry(entry)
    }
    @objc func menuOpenWith(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ArchiveEntry else { return }
        document?.openEntryWith(entry)
    }
    @objc func menuDeleteSelection(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? NSArray else { return }
        let idList = ids.compactMap { $0 as? ArchiveEntry.ID }
        document?.deletePaths(idList)
    }
    @objc func menuExtractChecked(_ sender: NSMenuItem) { document?.extractSelection() }
    @objc func menuExtractSelection(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? NSArray, let doc = document else { return }
        let idArray = ids.compactMap { $0 as? ArchiveEntry.ID }
        guard !idArray.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Extract Here"; panel.message = "Choose destination folder"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        doc.extractSelection(forIDs: idArray, to: dest)
    }
    @objc func menuExtractHere(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? NSArray, let doc = document,
              let archiveURL = doc.archiveURL else { return }
        let dest = archiveURL.deletingLastPathComponent()
        let idArray = ids.compactMap { $0 as? ArchiveEntry.ID }
        guard !idArray.isEmpty else { return }
        doc.extractSelection(forIDs: idArray, to: dest)
    }

    /// Resolve selected IDs to extractable file paths.
    /// If a selected entry is a directory, include all files under that directory.
    private func resolveExtractPaths(ids: NSArray) -> [String] {
        guard let doc = document else { return [] }
        var paths: [String] = []
        for case let eid as ArchiveEntry.ID in ids {
            guard let e = rows.first(where: { $0.entry.id == eid })?.entry else { continue }
            if e.isDirectory {
                // Add all files under this directory
                let prefix = e.path.hasSuffix("/") ? e.path : e.path + "/"
                let children = doc.entries.filter { !$0.isDirectory && $0.path.hasPrefix(prefix) }
                paths.append(contentsOf: children.map(\.path))
            } else {
                paths.append(e.path)
            }
        }
        return Array(Set(paths)) // deduplicate
    }
    @objc func menuDeleteChecked(_ sender: NSMenuItem) { document?.deleteSelection() }

    @objc func menuRename(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ArchiveEntry,
              let table else { return }
        // Find the row for this entry and trigger inline editing
        guard let rowIdx = rows.firstIndex(where: { $0.entry.id == entry.id }) else { return }
        let nameColIdx = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard nameColIdx >= 0 else { return }
        if let cell = table.view(atColumn: nameColIdx, row: rowIdx, makeIfNecessary: false) as? NameCellView {
            cell.beginRename()
        }
    }

    // MARK: Cell builders

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

// MARK: - Drag and Drop (NSFilePromiseProviderDelegate)

extension Coordinator: NSFilePromiseProviderDelegate {
    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        let fetchName: @MainActor () -> String = {
            guard let userInfo = filePromiseProvider.userInfo as? [String: Any],
                  let entryID = userInfo["entryID"] as? ArchiveEntry.ID,
                  let doc = self.document,
                  let entry = doc.entries.first(where: { $0.id == entryID }) else {
                return "Unknown"
            }
            return entry.name
        }
        
        if Thread.isMainThread {
            return MainActor.assumeIsolated { fetchName() }
        } else {
            return DispatchQueue.main.sync {
                MainActor.assumeIsolated { fetchName() }
            }
        }
    }
    
    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping @Sendable (Error?) -> Void) {
        Task { @MainActor in
            guard let userInfo = filePromiseProvider.userInfo as? [String: Any],
                  let entryID = userInfo["entryID"] as? ArchiveEntry.ID,
                  let doc = self.document else {
                completionHandler(ArchiveError.notFound("Invalid drag state"))
                return
            }
            doc.extractDragItem(entryID: entryID, to: url, completion: completionHandler)
        }
    }
}
