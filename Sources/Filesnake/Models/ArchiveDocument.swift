import Foundation
import AppKit
import SwiftUI

@MainActor
final class ArchiveDocument: ObservableObject {
    @Published private(set) var archiveURL: URL?
    @Published private(set) var format: ArchiveFormat?
    @Published private(set) var entries: [ArchiveEntry] = []
    /// Only file (non-directory) entry IDs are stored here. A folder's
    /// checkbox state is *derived* from whether all its file descendants
    /// are in this set — see `folderCheckState(_:)`.
    @Published var checked: Set<ArchiveEntry.ID> = [] {
        didSet {
            if oldValue != checked { folderCheckStateCache.removeAll() }
        }
    }
    @Published var focused: ArchiveEntry.ID?
    @Published var searchText: String = ""
    @Published private(set) var isBusy: Bool = false
    @Published var lastError: String?
    /// URL of a file selected in sidebar favorites (for preview pane)
    @Published var sidebarPreviewURL: URL?
    @Published private(set) var currentFolderPath: String = ""
    @Published var sortKey: SortKey = .name
    @Published var sortAscending: Bool = true
    @Published var expandedFolders: Set<String> = []

    enum SortKey: String {
        case name, size, compressed, modified
    }

    /// A row in the display list, wrapping an ArchiveEntry with indentation info.
    struct DisplayRow: Identifiable {
        let entry: ArchiveEntry
        let depth: Int
        var id: ArchiveEntry.ID { entry.id }
    }

    private var handler: ArchiveHandler?
    private var previewCacheDir: URL?

    // MARK: - Indices (rebuilt once per `entries` change, used for O(1) lookups)

    /// Bumped every time `entries` is replaced, used as cache-invalidation key.
    private var entriesEpoch: Int = 0
    /// O(1) lookup by entry ID.
    private var entriesByID: [ArchiveEntry.ID: ArchiveEntry] = [:]
    /// Direct children of a directory prefix. Root is the empty string.
    /// Values are already sorted by the current sort order at build-time, but
    /// the sort-specific cache is maintained separately below.
    private var childrenByDirKey: [String: [ArchiveEntry]] = [:]
    /// Precomputed recursive uncompressed size per directory prefix.
    private var folderSizeByPath: [String: UInt64] = [:]
    /// Precomputed recursive compressed size per directory prefix.
    private var folderCompressedSizeByPath: [String: UInt64] = [:]
    /// Precomputed set of file-entry IDs per directory prefix.
    private var folderFileIDsByPath: [String: Set<ArchiveEntry.ID>] = [:]
    /// Cached check-state per folder entry. Invalidated when `checked` changes.
    private var folderCheckStateCache: [ArchiveEntry.ID: FolderCheckState] = [:]

    // MARK: - Display-row memoization

    private struct DisplaySig: Hashable {
        let epoch: Int
        let folder: String
        let expanded: Set<String>
        let sortKey: SortKey
        let ascending: Bool
    }
    private var cachedDisplaySig: DisplaySig?
    private var cachedDisplayRows: [DisplayRow] = []
    private struct FilteredSig: Hashable {
        let displaySig: DisplaySig
        let search: String
    }
    private var cachedFilteredSig: FilteredSig?
    private var cachedFilteredRows: [DisplayRow] = []

    enum FolderCheckState {
        case unchecked, mixed, checked
    }

    // MARK: - Computed lists

    /// Direct children of a directory prefix (O(1) dictionary hit).
    /// `prefix` is the normalized directory key: `""` for root,
    /// `"a/b/"` for a subdirectory.
    private func entriesAtLevel(_ prefix: String) -> [ArchiveEntry] {
        childrenByDirKey[prefix] ?? []
    }

    /// Build the display list with inline-expanded folders. Memoized by
    /// `(epoch, currentFolderPath, expandedFolders, sortKey, ascending)` so
    /// that frequent `@Published` ticks (checked, focused, searchText, etc.)
    /// don't retrigger a full tree walk.
    var displayRows: [DisplayRow] {
        let sig = DisplaySig(
            epoch: entriesEpoch,
            folder: currentFolderPath,
            expanded: expandedFolders,
            sortKey: sortKey,
            ascending: sortAscending)
        if sig == cachedDisplaySig { return cachedDisplayRows }
        let rows = buildDisplayRows(at: currentFolderPath, depth: 0)
        cachedDisplaySig = sig
        cachedDisplayRows = rows
        return rows
    }

    private func buildDisplayRows(at prefix: String, depth: Int) -> [DisplayRow] {
        let levelEntries = sortEntries(entriesAtLevel(prefix))
        var rows: [DisplayRow] = []
        rows.reserveCapacity(levelEntries.count)
        for entry in levelEntries {
            rows.append(DisplayRow(entry: entry, depth: depth))
            if entry.isDirectory, expandedFolders.contains(entry.path) {
                let childPrefix = normalizedDirectoryPath(for: entry.path)
                rows.append(contentsOf: buildDisplayRows(at: childPrefix, depth: depth + 1))
            }
        }
        return rows
    }

    var visibleEntries: [ArchiveEntry] {
        displayRows.map(\.entry)
    }

    var filteredEntries: [ArchiveEntry] {
        filteredDisplayRows.map(\.entry)
    }

    /// Filtered display rows (keeps depth info for indentation). Memoized so
    /// that unrelated `@Published` mutations do not re-filter the full tree.
    var filteredDisplayRows: [DisplayRow] {
        let base = displayRows
        guard !searchText.isEmpty else { return base }
        let sig = FilteredSig(
            displaySig: cachedDisplaySig ?? DisplaySig(
                epoch: entriesEpoch, folder: currentFolderPath,
                expanded: expandedFolders, sortKey: sortKey, ascending: sortAscending),
            search: searchText)
        if sig == cachedFilteredSig { return cachedFilteredRows }
        let q = searchText.lowercased()
        let rows = base.filter {
            $0.entry.name.lowercased().contains(q) || $0.entry.path.lowercased().contains(q)
        }
        cachedFilteredSig = sig
        cachedFilteredRows = rows
        return rows
    }

    var checkedEntries: [ArchiveEntry] {
        entries.filter { checked.contains($0.id) }
    }

    var currentEntry: ArchiveEntry? {
        guard let id = focused else { return nil }
        return entries.first { $0.id == id }
    }

    // MARK: - Folder expansion

    func toggleExpanded(_ entry: ArchiveEntry) {
        guard entry.isDirectory else { return }
        if expandedFolders.contains(entry.path) {
            expandedFolders.remove(entry.path)
        } else {
            expandedFolders.insert(entry.path)
        }
    }

    func isExpanded(_ entry: ArchiveEntry) -> Bool {
        expandedFolders.contains(entry.path)
    }

    var breadcrumbs: [String] {
        guard !currentFolderPath.isEmpty else { return [] }
        let trimmed = currentFolderPath.hasSuffix("/")
            ? String(currentFolderPath.dropLast()) : currentFolderPath
        return trimmed.split(separator: "/").map(String.init)
    }

    // MARK: - Folder sizes

    /// Recursive uncompressed size of all files inside a directory entry.
    func folderSize(for entry: ArchiveEntry) -> UInt64 {
        guard entry.isDirectory else { return entry.uncompressedSize }
        let key = normalizedDirectoryPath(for: entry.path)
        if let cached = folderSizeCache[key] { return cached }
        let size = entries
            .filter { !$0.isDirectory && $0.path.hasPrefix(key) }
            .reduce(UInt64(0)) { $0 + $1.uncompressedSize }
        folderSizeCache[key] = size
        return size
    }

    /// Recursive compressed size of all files inside a directory entry.
    func folderCompressedSize(for entry: ArchiveEntry) -> UInt64 {
        guard entry.isDirectory else { return entry.compressedSize }
        let key = normalizedDirectoryPath(for: entry.path)
        if let cached = folderCompressedSizeCache[key] { return cached }
        let size = entries
            .filter { !$0.isDirectory && $0.path.hasPrefix(key) }
            .reduce(UInt64(0)) { $0 + $1.compressedSize }
        folderCompressedSizeCache[key] = size
        return size
    }

    // MARK: - Navigation

    /// Derived checkbox state for any entry. Files use literal membership;
    /// folders are derived from whether their file descendants are all
    /// checked (tri-state: unchecked / mixed / checked).
    func folderCheckState(_ entry: ArchiveEntry) -> FolderCheckState {
        if !entry.isDirectory {
            return checked.contains(entry.id) ? .checked : .unchecked
        }
        if let cached = folderCheckStateCache[entry.id] { return cached }
        let fileIDs = fileDescendantIDs(of: entry)
        let state: FolderCheckState
        if fileIDs.isEmpty {
            state = .unchecked
        } else {
            // Count without allocating an intermediate set.
            var hit = 0
            for id in fileIDs where checked.contains(id) { hit += 1 }
            if hit == 0 { state = .unchecked }
            else if hit == fileIDs.count { state = .checked }
            else { state = .mixed }
        }
        folderCheckStateCache[entry.id] = state
        return state
    }

    func isChecked(_ entry: ArchiveEntry) -> Bool {
        folderCheckState(entry) == .checked
    }

    func toggleChecked(_ id: ArchiveEntry.ID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        let current = folderCheckState(entry)
        // .mixed behaves like .unchecked on click — promote to fully checked,
        // matching standard macOS tri-state checkbox behavior.
        let shouldCheck = current != .checked
        applyChecked(shouldCheck, to: [entry])
    }

    /// Bulk set for a list of entries (used by right-click menu). Propagates
    /// through file descendants when any entry is a directory.
    func setChecked(_ value: Bool, forIDs ids: [ArchiveEntry.ID]) {
        let targets = ids.compactMap { id in entries.first(where: { $0.id == id }) }
        applyChecked(value, to: targets)
    }

    /// Apply a single atomic mutation to `checked` so @Published fires once.
    private func applyChecked(_ value: Bool, to targets: [ArchiveEntry]) {
        var touched: Set<ArchiveEntry.ID> = []
        for entry in targets {
            if entry.isDirectory {
                touched.formUnion(fileDescendantIDs(of: entry))
            } else {
                touched.insert(entry.id)
            }
        }
        guard !touched.isEmpty else { return }
        var updated = checked
        if value { updated.formUnion(touched) } else { updated.subtract(touched) }
        checked = updated  // single @Published notification
    }

    /// Set of file-entry IDs under a folder path. Cached for perf on huge
    /// archives (a single subset check can otherwise scan 100k+ entries).
    private func fileDescendantIDs(of folder: ArchiveEntry) -> Set<ArchiveEntry.ID> {
        let key = normalizedDirectoryPath(for: folder.path)
        if let cached = folderFileIDsCache[key] { return cached }
        var ids: Set<ArchiveEntry.ID> = []
        ids.reserveCapacity(64)
        for entry in entries where !entry.isDirectory && entry.path.hasPrefix(key) {
            ids.insert(entry.id)
        }
        folderFileIDsCache[key] = ids
        return ids
    }

    func checkAllVisible() {
        // Collect file IDs of visible entries (expanding any visible folders).
        var ids: Set<ArchiveEntry.ID> = []
        for e in filteredEntries {
            if e.isDirectory {
                ids.formUnion(fileDescendantIDs(of: e))
            } else {
                ids.insert(e.id)
            }
        }
        guard !ids.isEmpty else { return }
        var updated = checked
        updated.formUnion(ids)
        checked = updated
    }

    func uncheckAll() { checked.removeAll() }

    func enterFolder(_ entry: ArchiveEntry) {
        guard entry.isDirectory else { return }
        currentFolderPath = normalizedDirectoryPath(for: entry.path)
        focused = nil
    }

    func goBack() {
        guard !currentFolderPath.isEmpty else { return }
        let trimmed = currentFolderPath.hasSuffix("/")
            ? String(currentFolderPath.dropLast()) : currentFolderPath
        let parent = (trimmed as NSString).deletingLastPathComponent
        currentFolderPath = parent.isEmpty ? "" : parent + "/"
        focused = nil
    }

    func goToRoot() { currentFolderPath = ""; focused = nil }

    func goToBreadcrumb(index: Int) {
        guard index >= 0 else { goToRoot(); return }
        let parts = breadcrumbs
        guard index < parts.count else { return }
        currentFolderPath = parts.prefix(index + 1).joined(separator: "/") + "/"
        focused = nil
    }

    func toggleSort(key: SortKey) {
        if sortKey == key { sortAscending.toggle() }
        else { sortKey = key; sortAscending = true }
    }

    var stats: (count: Int, totalSize: UInt64) {
        let files = entries.filter { !$0.isDirectory }
        return (files.count, files.reduce(0) { $0 + $1.uncompressedSize })
    }

    // MARK: - Open / Close

    func open(url: URL) {
        isBusy = true
        defer { isBusy = false }
        do {
            let newHandler = try ArchiveHandlerFactory.make(url: url)
            let newEntries = try newHandler.list()
            // Clean up old preview cache
            if let dir = previewCacheDir { try? FileManager.default.removeItem(at: dir) }
            // Atomically swap state — no flash to empty
            self.handler = newHandler
            self.archiveURL = url
            self.format = newHandler.format
            self.entries = newEntries
            self.checked = []
            self.focused = nil
            self.searchText = ""
            self.currentFolderPath = ""
            self.expandedFolders = []
            self.folderSizeCache = [:]
            self.folderCompressedSizeCache = [:]
            self.folderFileIDsCache = [:]
            self.folderCheckStateCache = [:]
            self.previewCacheDir = makePreviewCacheDir(for: url)
            self.sidebarPreviewURL = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func close() {
        handler = nil; archiveURL = nil; format = nil
        entries = []; checked = []; focused = nil
        searchText = ""; currentFolderPath = ""
        expandedFolders = []
        folderSizeCache = [:]; folderCompressedSizeCache = [:]
        folderFileIDsCache = [:]; folderCheckStateCache = [:]
        if let dir = previewCacheDir { try? FileManager.default.removeItem(at: dir) }
        previewCacheDir = nil
    }

    // MARK: - Extract / Delete

    func extractSelection() {
        guard let handler, !checked.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Extract Here"; panel.message = "Choose a destination folder"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let paths = checkedEntries.filter { !$0.isDirectory }.map { $0.path }
        runBusy({ try handler.extract(paths: paths, to: dest) },
                thenOnMain: { NSWorkspace.shared.open(dest) })
    }

    func extractPaths(_ paths: [String], to dest: URL) {
        guard let handler else { return }
        runBusy({ try handler.extract(paths: paths, to: dest) },
                thenOnMain: { NSWorkspace.shared.open(dest) })
    }

    /// Extract checked entries to a preset destination (no dialog).
    func extractCheckedTo(_ dest: URL) {
        guard let handler, !checked.isEmpty else { return }
        let paths = checkedEntries.filter { !$0.isDirectory }.map { $0.path }
        guard !paths.isEmpty else { return }
        runBusy({ try handler.extract(paths: paths, to: dest) },
                thenOnMain: { NSWorkspace.shared.open(dest) })
    }

    func extractAll() {
        guard let handler else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Extract Here"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let paths = entries.filter { !$0.isDirectory }.map { $0.path }
        runBusy({ try handler.extract(paths: paths, to: dest) },
                thenOnMain: { NSWorkspace.shared.open(dest) })
    }

    func deleteSelection() {
        guard let handler, format?.supportsDeletion == true else {
            lastError = "This archive type does not support deletion."; return
        }
        // Approach A: `checked` only holds file IDs. Also delete the
        // directory-marker entries whose descendants are fully checked, so
        // the folder disappears from the listing entirely.
        let filePaths = checkedEntries.map(\.path)
        let folderPaths = entries
            .filter { $0.isDirectory && folderCheckState($0) == .checked }
            .map(\.path)
        let paths = Array(Set(filePaths + folderPaths))
        guard !paths.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \(paths.count) entry(ies) from archive?"
        alert.informativeText = "This rewrites the archive and cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runBusy({
            try handler.delete(paths: paths)
            return try handler.list()
        }, thenOnMain: { [weak self] newEntries in
            guard let self else { return }
            self.entries = newEntries
            self.folderSizeCache = [:]
            self.folderCompressedSizeCache = [:]
            self.folderFileIDsCache = [:]
            self.folderCheckStateCache = [:]
            // Entry IDs are regenerated on each list() — `checked` is stale.
            self.checked = []
            if let f = self.focused, !newEntries.contains(where: { $0.id == f }) { self.focused = nil }
        })
    }

    /// Delete a specific set of entries (regardless of checked state).
    /// Used by the right-click "Delete" menu item for a selection.
    func deletePaths(_ targetIDs: [ArchiveEntry.ID]) {
        guard let handler, format?.supportsDeletion == true else {
            lastError = "This archive type does not support deletion."; return
        }
        // Expand folder targets to include all descendants (files + sub-folders).
        var paths: Set<String> = []
        for id in targetIDs {
            guard let e = entries.first(where: { $0.id == id }) else { continue }
            if e.isDirectory {
                let prefix = normalizedDirectoryPath(for: e.path)
                for sub in entries where sub.path.hasPrefix(prefix) || sub.path == e.path {
                    paths.insert(sub.path)
                }
                paths.insert(e.path)
            } else {
                paths.insert(e.path)
            }
        }
        guard !paths.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \(paths.count) entry(ies) from archive?"
        alert.informativeText = "This rewrites the archive and cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let pathList = Array(paths)
        runBusy({
            try handler.delete(paths: pathList)
            return try handler.list()
        }, thenOnMain: { [weak self] newEntries in
            guard let self else { return }
            self.entries = newEntries
            self.folderSizeCache = [:]
            self.folderCompressedSizeCache = [:]
            self.folderFileIDsCache = [:]
            self.folderCheckStateCache = [:]
            self.checked = []
            if let f = self.focused, !newEntries.contains(where: { $0.id == f }) { self.focused = nil }
        })
    }

    /// Extract a single file entry to the preview/temp cache and return its URL.
    /// For folders, extracts all descendants and returns the folder URL.
    func materializeForOpen(_ entry: ArchiveEntry) -> URL? {
        guard let handler, let dir = previewCacheDir else { return nil }
        if entry.isDirectory {
            let prefix = normalizedDirectoryPath(for: entry.path)
            let childFiles = entries.filter { !$0.isDirectory && $0.path.hasPrefix(prefix) }
            guard !childFiles.isEmpty else {
                // Empty folder — create an empty directory to open.
                let target = dir.appendingPathComponent(entry.path, isDirectory: true)
                try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                return target
            }
            do {
                try handler.extract(paths: childFiles.map(\.path), to: dir)
                return dir.appendingPathComponent(entry.path, isDirectory: true)
            } catch {
                lastError = error.localizedDescription
                return nil
            }
        } else {
            let target = dir.appendingPathComponent(entry.path)
            if FileManager.default.fileExists(atPath: target.path) { return target }
            do {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try handler.extractToMemory(path: entry.path)
                try data.write(to: target)
                return target
            } catch {
                lastError = error.localizedDescription
                return nil
            }
        }
    }

    /// Extract and open the entry with its default application (or reveal
    /// in Finder for folders).
    func openEntry(_ entry: ArchiveEntry) {
        guard let url = materializeForOpen(entry) else { return }
        if entry.isDirectory {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Extract the entry and open it with a user-chosen application.
    func openEntryWith(_ entry: ArchiveEntry) {
        guard let url = materializeForOpen(entry) else { return }

        let panel = NSOpenPanel()
        panel.title = "Choose Application"
        panel.prompt = "Open"
        panel.message = "Choose an application to open \(entry.name)"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if let apps = URL(string: "file:///Applications") { panel.directoryURL = apps }

        guard panel.runModal() == .OK, let appURL = panel.url else { return }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                configuration: config) { _, error in
            if let error {
                Task { @MainActor [weak self] in
                    self?.lastError = "Failed to open: \(error.localizedDescription)"
                }
            }
        }
    }

    func materializeForPreview(_ entry: ArchiveEntry) -> URL? {
        guard let handler, let dir = previewCacheDir, !entry.isDirectory else { return nil }
        let target = dir.appendingPathComponent(entry.path)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try handler.extractToMemory(path: entry.path)
            try data.write(to: target)
            return target
        } catch { lastError = error.localizedDescription; return nil }
    }

    // MARK: - Sorting

    private func sortEntries(_ list: [ArchiveEntry]) -> [ArchiveEntry] {
        list.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            let asc = sortAscending
            switch sortKey {
            case .name:
                let cmp = a.name.localizedCaseInsensitiveCompare(b.name)
                return asc ? cmp == .orderedAscending : cmp == .orderedDescending
            case .size:
                let sa = a.isDirectory ? folderSize(for: a) : a.uncompressedSize
                let sb = b.isDirectory ? folderSize(for: b) : b.uncompressedSize
                return asc ? sa < sb : sa > sb
            case .compressed:
                let ca = a.isDirectory ? folderCompressedSize(for: a) : a.compressedSize
                let cb = b.isDirectory ? folderCompressedSize(for: b) : b.compressedSize
                return asc ? ca < cb : ca > cb
            case .modified:
                let ad = a.modified ?? .distantPast
                let bd = b.modified ?? .distantPast
                return asc ? ad < bd : ad > bd
            }
        }
    }

    // MARK: - Helpers

    private func normalizedDirectoryPath(for path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    private func runBusy<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T,
        thenOnMain apply: @escaping @MainActor (T) -> Void
    ) {
        isBusy = true
        let box = WeakBox(self)
        Task.detached {
            do {
                let result = try work()
                await MainActor.run { apply(result); box.value?.isBusy = false }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run { box.value?.lastError = msg; box.value?.isBusy = false }
            }
        }
    }

    private func makePreviewCacheDir(for url: URL) -> URL? {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let stamp = "\(abs(url.path.hashValue))-\(Int(Date().timeIntervalSince1970))"
        let dir = base?
            .appendingPathComponent("Filesnake", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        if let dir { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        return dir
    }
}

// MARK: - Sendable weak-reference box

private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
