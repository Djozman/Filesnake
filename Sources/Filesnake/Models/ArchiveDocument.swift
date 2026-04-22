import Foundation
import AppKit
import SwiftUI
import ZIPFoundation

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
    /// Non-nil while a save is in progress; value is 0.0 – 1.0 progress.
    @Published private(set) var saveProgress: Double? = nil
    @Published private(set) var saveStatusText: String = ""
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

    /// Whether the user has made unsaved modifications (deletes, renames).
    @Published private(set) var isDirty: Bool = false
    /// Snapshot of the entries as they were at the last save/open.
    /// Used to compute which original paths need extracting on save.
    private var originalEntries: [ArchiveEntry] = []
    /// The original format of the archive before any modifications.
    private var originalFormat: ArchiveFormat?

    // MARK: - Indices (rebuilt once per `entries` change via buildIndices())

    /// Bumped every time `entries` is replaced, used as cache-invalidation key.
    private var entriesEpoch: Int = 0
    /// O(1) lookup by entry ID.
    private var entriesByID: [ArchiveEntry.ID: ArchiveEntry] = [:]
    /// Direct children of a directory prefix. Key is "" for root, "a/b/" for subdirs.
    private var childrenByDirKey: [String: [ArchiveEntry]] = [:]
    /// Precomputed recursive uncompressed size per directory prefix.
    private var folderSizeByPath: [String: UInt64] = [:]
    /// Precomputed recursive compressed size per directory prefix.
    private var folderCompressedByPath: [String: UInt64] = [:]
    /// Precomputed set of file-entry IDs per directory prefix.
    private var folderFileIDsByPath: [String: Set<ArchiveEntry.ID>] = [:]
    /// Cached check-state per folder entry. Invalidated when `checked` changes.
    private var folderCheckStateCache: [ArchiveEntry.ID: FolderCheckState] = [:]
    /// Precomputed total file count and size for stats.
    private var cachedFileCount: Int = 0
    private var cachedTotalSize: UInt64 = 0

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

    // MARK: - Index building (single O(N) pass)

    /// Rebuilds all lookup indices from `entries`. Called once per open/reload.
    private func buildIndices() {
        entriesEpoch += 1
        entriesByID.removeAll(keepingCapacity: true)
        childrenByDirKey.removeAll(keepingCapacity: true)
        folderSizeByPath.removeAll(keepingCapacity: true)
        folderCompressedByPath.removeAll(keepingCapacity: true)
        folderFileIDsByPath.removeAll(keepingCapacity: true)
        folderCheckStateCache.removeAll(keepingCapacity: true)
        cachedDisplaySig = nil
        cachedFilteredSig = nil

        var fileCount = 0
        var totalSize: UInt64 = 0

        entriesByID.reserveCapacity(entries.count)

        for entry in entries {
            entriesByID[entry.id] = entry

            // Build childrenByDirKey: determine the parent directory key.
            let parentKey: String

            if entry.isDirectory {
                // "a/b/" → strip trailing slash → "a/b" → find last slash → "a/"
                let trimmed = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
                if let lastSlash = trimmed.lastIndex(of: "/") {
                    parentKey = String(trimmed[...lastSlash])
                } else {
                    parentKey = ""
                }
            } else {
                // "a/b/file.txt" → find last slash → "a/b/"
                if let lastSlash = entry.path.lastIndex(of: "/") {
                    parentKey = String(entry.path[...lastSlash])
                } else {
                    parentKey = ""
                }
            }
            childrenByDirKey[parentKey, default: []].append(entry)

            if !entry.isDirectory {
                fileCount += 1
                totalSize += entry.uncompressedSize

                // Accumulate folder sizes for every ancestor.
                var path = entry.path
                while let slashRange = path.range(of: "/", options: .backwards) {
                    let dirKey = String(path[..<slashRange.upperBound])
                    folderSizeByPath[dirKey, default: 0] += entry.uncompressedSize
                    folderCompressedByPath[dirKey, default: 0] += entry.compressedSize
                    folderFileIDsByPath[dirKey, default: []].insert(entry.id)
                    path = String(path[..<slashRange.lowerBound])
                }
            }
        }

        cachedFileCount = fileCount
        cachedTotalSize = totalSize
    }

    // MARK: - Computed lists

    /// Direct children of a directory prefix (O(1) dictionary hit).
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
        checked.compactMap { entriesByID[$0] }
    }

    var currentEntry: ArchiveEntry? {
        guard let id = focused else { return nil }
        return entriesByID[id]
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

    // MARK: - Folder sizes (O(1) from precomputed indices)

    /// Recursive uncompressed size of all files inside a directory entry.
    func folderSize(for entry: ArchiveEntry) -> UInt64 {
        guard entry.isDirectory else { return entry.uncompressedSize }
        return folderSizeByPath[normalizedDirectoryPath(for: entry.path)] ?? 0
    }

    /// Recursive compressed size of all files inside a directory entry.
    func folderCompressedSize(for entry: ArchiveEntry) -> UInt64 {
        guard entry.isDirectory else { return entry.compressedSize }
        return folderCompressedByPath[normalizedDirectoryPath(for: entry.path)] ?? 0
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
        guard let entry = entriesByID[id] else { return }
        let current = folderCheckState(entry)
        // .mixed behaves like .unchecked on click — promote to fully checked,
        // matching standard macOS tri-state checkbox behavior.
        let shouldCheck = current != .checked
        applyChecked(shouldCheck, to: [entry])
    }

    /// Bulk set for a list of entries (used by right-click menu). Propagates
    /// through file descendants when any entry is a directory.
    func setChecked(_ value: Bool, forIDs ids: [ArchiveEntry.ID]) {
        let targets = ids.compactMap { entriesByID[$0] }
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

    /// Set of file-entry IDs under a folder path (O(1) from precomputed index).
    private func fileDescendantIDs(of folder: ArchiveEntry) -> Set<ArchiveEntry.ID> {
        folderFileIDsByPath[normalizedDirectoryPath(for: folder.path)] ?? []
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
        (cachedFileCount, cachedTotalSize)
    }

    // MARK: - Open / Close

    func open(url: URL, completion: (@MainActor @Sendable () -> Void)? = nil) {
        // If the current archive has unsaved changes, prompt to save first.
        if isDirty {
            let result = promptSaveChanges()
            switch result {
            case .save:     saveArchive()
            case .dontSave: break
            case .cancel:   return
            }
        }
        // Clean up old state without prompting again
        if let dir = previewCacheDir { try? FileManager.default.removeItem(at: dir) }
        handler = nil

        // Show the spinner while the archive loads
        isBusy = true
        let newURL = url
        let box = WeakBox(self)
        Task.detached {
            do {
                let newHandler = try ArchiveHandlerFactory.make(url: newURL)
                let rawEntries = try newHandler.list()
                // Drop macOS metadata noise that Finder's "Compress" silently
                // injects: __MACOSX/ (AppleDouble resource forks), ._* sidecars,
                // and .DS_Store files. These are never useful to preserve, they
                // confuse rename (only the visible entry gets renamed while
                // the shadow entry keeps the old name), and they show up as
                // hidden junk when the zip is re-extracted.
                let newEntries = rawEntries.filter {
                    !ArchiveDocument.isMacMetadataPath($0.path)
                }
                await MainActor.run {
                    guard let self = box.value else { return }
                    self.handler = newHandler
                    self.archiveURL = newURL
                    self.format = newHandler.format
                    self.originalFormat = newHandler.format
                    self.entries = newEntries
                    self.originalEntries = newEntries
                    // Stay clean on open even if we stripped metadata. The
                    // on-disk archive still contains the junk; we just don't
                    // surface it. If the user later edits and saves, the
                    // cleaned set is what gets written. If they never save,
                    // the archive stays untouched.
                    self.isDirty = false
                    self.checked = []
                    self.focused = nil
                    self.searchText = ""
                    self.currentFolderPath = ""
                    self.expandedFolders = []
                    self.previewCacheDir = self.makePreviewCacheDir(for: newURL)
                    self.sidebarPreviewURL = nil
                    self.buildIndices()
                    self.isBusy = false
                    completion?()
                }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run {
                    box.value?.lastError = msg
                    box.value?.isBusy = false
                    completion?()
                }
            }
        }
    }

    /// Returns true if close proceeded, false if the user cancelled.
    @discardableResult
    func close() -> Bool {
        if isDirty {
            let result = promptSaveChanges()
            switch result {
            case .save:
                saveArchive()
            case .dontSave:
                break // discard
            case .cancel:
                return false
            }
        }
        handler = nil; archiveURL = nil; format = nil
        originalFormat = nil
        entries = []; originalEntries = []; checked = []; focused = nil
        searchText = ""; currentFolderPath = ""
        expandedFolders = []; isDirty = false
        if let dir = previewCacheDir { try? FileManager.default.removeItem(at: dir) }
        previewCacheDir = nil
        buildIndices()
        return true
    }

    enum SavePromptResult { case save, dontSave, cancel }

    private func promptSaveChanges() -> SavePromptResult {
        let alert = NSAlert()
        alert.messageText = "Save changes to \"\(archiveURL?.lastPathComponent ?? "archive")\"?"
        alert.informativeText = "Your changes will be lost if you don\u{2019}t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don\u{2019}t Save")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:  return .save
        case .alertSecondButtonReturn: return .dontSave
        default:                       return .cancel
        }
    }

    // MARK: - Extract / Delete

    func extractSelection() {
        guard let handler, !checked.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Extract Here"; panel.message = "Choose a destination folder"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let fileEntries = checkedEntries.filter { !$0.isDirectory }
        extractEntries(fileEntries, to: dest, using: handler)
    }

    func extractPaths(_ paths: [String], to dest: URL) {
        guard let handler else { return }
        // Find entries matching these paths
        let matching = entries.filter { paths.contains($0.path) && !$0.isDirectory }
        let rebasePrefix = currentFolderPath
        extractEntries(
            matching,
            to: dest,
            using: handler,
            outputPath: { entry in
                guard !rebasePrefix.isEmpty, entry.path.hasPrefix(rebasePrefix) else {
                    return entry.path
                }
                return String(entry.path.dropFirst(rebasePrefix.count))
            }
        )
    }

    /// Extract checked entries to a preset destination (no dialog).
    func extractCheckedTo(_ dest: URL) {
        guard let handler, !checked.isEmpty else { return }
        let fileEntries = checkedEntries.filter { !$0.isDirectory }
        guard !fileEntries.isEmpty else { return }
        extractEntries(fileEntries, to: dest, using: handler)
    }

    func extractAll() {
        guard let handler else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Extract Here"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let fileEntries = entries.filter { !$0.isDirectory }
        extractEntries(fileEntries, to: dest, using: handler)
    }

    func extractEntries(
        _ entriesToExtract: [ArchiveEntry],
        to dest: URL,
        using handler: ArchiveHandler,
        outputPath: @escaping @Sendable (ArchiveEntry) -> String = { $0.path },
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        let originalPaths = entriesToExtract.map(\.originalPath)
        let box = WeakBox(self)
        // Snapshot the (non-Sendable) outputPath closure into a Sendable-by-value
        // array, keyed by entry ID, so the @Sendable work closure doesn't have
        // to capture a non-Sendable function reference.
        let outputPaths: [ArchiveEntry.ID: String] = Dictionary(
            uniqueKeysWithValues: entriesToExtract.map { ($0.id, outputPath($0)) })
        runBusy({
            // FileManager.default is a shared reference — access it fresh
            // inside this @Sendable closure rather than capturing a local
            // `fm` that Swift 6 flags as non-Sendable capture.
            let tmpDir = dest.appendingPathComponent(".filesnake-extract-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let totalBytes = entriesToExtract.reduce(0) { $0 + $1.uncompressedSize }
            
            // Start a detached task to monitor directory size and update progress
            let progressTask = Task.detached {
                while !Task.isCancelled {
                    let currentSize = ArchiveDocument.directorySize(url: tmpDir)
                    await MainActor.run {
                        if Task.isCancelled { return }
                        let prog = totalBytes > 0 ? Double(currentSize) / Double(totalBytes) : 1.0
                        // Keep progress between 0 and 0.99 until really done
                        box.value?.saveProgress = min(prog, 0.99)
                        
                        let extractedStr = ArchiveDocument.formatBytes(currentSize)
                        let totalStr = ArchiveDocument.formatBytes(totalBytes)
                        box.value?.saveStatusText = "Extracting\u{2026} \(extractedStr) of \(totalStr)"
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }
            }
            
            defer {
                progressTask.cancel()
                try? FileManager.default.removeItem(at: tmpDir)
            }

            // 1. Extract everything to the temporary directory using original paths
            try handler.extract(paths: originalPaths, to: tmpDir)

            progressTask.cancel()
            Task { @MainActor in box.value?.saveProgress = 1.0 }

            // 2. Identify top-level components of the requested output paths
            var topLevelPaths = Set<String>()
            for e in entriesToExtract {
                let outPath = outputPaths[e.id] ?? e.path
                let firstComponent = outPath.split(separator: "/").first.map(String.init) ?? outPath
                topLevelPaths.insert(firstComponent)
            }

            // 3. Resolve collisions for each top-level item at the destination
            // `let` binding: the rename map is built here and then only read
            // from the per-entry move loop below. Declaring it `let` (vs.
            // `var` + mutation inside the loop) keeps Swift 6 strict
            // concurrency happy — no captured-var-in-@Sendable-closure.
            let topLevelRenameMap: [String: String] = {
                var map = [String: String]()
                for top in topLevelPaths {
                    let desiredDst = dest.appendingPathComponent(top)
                    let finalDst = ArchiveDocument.uniqueURL(for: desiredDst)
                    map[top] = finalDst.lastPathComponent
                }
                return map
            }()

            // 4. Move files from tmpDir to dest, applying the top-level rename
            let fileManager = FileManager.default
            for e in entriesToExtract {
                let src = tmpDir.appendingPathComponent(e.originalPath)
                guard fileManager.fileExists(atPath: src.path) else { continue }

                let outPath = outputPaths[e.id] ?? e.path
                var components = outPath.split(separator: "/").map(String.init)
                if let first = components.first, let newFirst = topLevelRenameMap[first] {
                    components[0] = newFirst
                }

                let remappedOutPath = components.joined(separator: "/")
                let finalDst = dest.appendingPathComponent(remappedOutPath)

                try fileManager.createDirectory(at: finalDst.deletingLastPathComponent(), withIntermediateDirectories: true)
                // If it's a directory, we don't need to move it if it's empty, but we'll ensure the dir exists
                if e.isDirectory {
                    try fileManager.createDirectory(at: finalDst, withIntermediateDirectories: true)
                } else {
                    if fileManager.fileExists(atPath: finalDst.path) { try fileManager.removeItem(at: finalDst) }
                    try fileManager.moveItem(at: src, to: finalDst)
                }
            }
        }, thenOnMain: { result in
            switch result {
            case .success:
                completion?(true)
            case .failure(let error):
                // Ensure completion is called even on failure so the HUD does not hang
                completion?(false)
                print("Extraction error: \(error.localizedDescription)")
            }
        })
    }
    
    /// Extracts a specific dragged item to a URL provided by Finder via NSFilePromiseProvider.
    func extractDragItem(entryID: ArchiveEntry.ID, to targetURL: URL, completion: @escaping @Sendable (Error?) -> Void) {
        guard let handler else {
            completion(ArchiveError.readFailed("No handler"))
            return
        }
        
        guard let entry = entries.first(where: { $0.id == entryID }) else {
            completion(ArchiveError.notFound("Entry not found"))
            return
        }
        
        let prefix = entry.isDirectory ? (entry.path.hasSuffix("/") ? entry.path : entry.path + "/") : entry.path
        let matching = entries.filter { !$0.isDirectory && ($0.path == entry.path || $0.path.hasPrefix(prefix)) }
        let originalPaths = matching.map(\.originalPath)
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let fm = FileManager.default
                // For drag & drop, we must use the targetURL's volume for the tmpDir
                // so we don't cross volumes when doing the moveItem.
                let tmpDir = targetURL.deletingLastPathComponent().appendingPathComponent(".filesnake-drag-\(UUID().uuidString)")
                try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: tmpDir) }
                
                try handler.extract(paths: originalPaths, to: tmpDir)
                
                for e in matching {
                    let src = tmpDir.appendingPathComponent(e.originalPath)
                    guard fm.fileExists(atPath: src.path) else { continue }
                    
                    let relativePath: String
                    if entry.isDirectory {
                        relativePath = String(e.path.dropFirst(prefix.count))
                    } else {
                        relativePath = ""
                    }
                    
                    let finalDst = relativePath.isEmpty ? targetURL : targetURL.appendingPathComponent(relativePath)
                    try fm.createDirectory(at: finalDst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    
                    if fm.fileExists(atPath: finalDst.path) {
                        try fm.removeItem(at: finalDst)
                    }
                    try fm.moveItem(at: src, to: finalDst)
                }
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    /// Finds an available URL by appending a number if the file already exists (e.g., "file 2.txt")
    nonisolated private static func uniqueURL(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        
        var counter = 2
        var newURL = url
        while fm.fileExists(atPath: newURL.path) {
            let newName = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            newURL = dir.appendingPathComponent(newName)
            counter += 1
        }
        return newURL
    }

    /// If all selected paths share the same top-level folder, returns that
    /// folder prefix (e.g. "claude/") so extraction can be rebased to the
    /// exact selected subtree ("monkey/..."), not wrapped in archive root.
    private func commonTopLevelPrefix(for paths: [String]) -> String? {
        guard let first = paths.first else { return nil }
        let firstParts = first.split(separator: "/", omittingEmptySubsequences: true)
        guard let top = firstParts.first else { return nil }
        let topPrefix = String(top) + "/"
        let allSameTop = paths.allSatisfy { $0.hasPrefix(topPrefix) }
        return allSameTop ? topPrefix : nil
    }

    func deleteSelection() {
        guard format?.supportsDeletion == true else {
            lastError = "This archive type does not support deletion."; return
        }
        // Gather files + fully-checked folders
        let filePaths = checkedEntries.map(\.path)
        let folderPaths = entries
            .filter { $0.isDirectory && folderCheckState($0) == .checked }
            .map(\.path)
        let pathsToDelete = Set(filePaths + folderPaths)
        guard !pathsToDelete.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \(pathsToDelete.count) entry(ies) from archive?"
        alert.informativeText = "Changes won\u{2019}t be written to disk until you save."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Virtual delete: remove from in-memory list immediately.
        // The archive file stays unchanged — the user extracts only what they
        // need, and can ⌘S to rewrite the archive when they have enough space.
        entries.removeAll { pathsToDelete.contains($0.path) }
        checked = []
        isDirty = true
        buildIndices()
        if let f = focused, entriesByID[f] == nil { focused = nil }
    }

    /// Delete a specific set of entries (regardless of checked state).
    func deletePaths(_ targetIDs: [ArchiveEntry.ID]) {
        guard format?.supportsDeletion == true else {
            lastError = "This archive type does not support deletion."; return
        }
        // Expand folder targets to include all descendants.
        var pathsToDelete: Set<String> = []
        for id in targetIDs {
            guard let e = entriesByID[id] else { continue }
            if e.isDirectory {
                let prefix = normalizedDirectoryPath(for: e.path)
                for sub in entries where sub.path.hasPrefix(prefix) || sub.path == e.path {
                    pathsToDelete.insert(sub.path)
                }
                pathsToDelete.insert(e.path)
            } else {
                pathsToDelete.insert(e.path)
            }
        }
        guard !pathsToDelete.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \(pathsToDelete.count) entry(ies) from archive?"
        alert.informativeText = "Changes won\u{2019}t be written to disk until you save."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        entries.removeAll { pathsToDelete.contains($0.path) }
        checked.subtract(targetIDs)
        isDirty = true
        buildIndices()
        if let f = focused, entriesByID[f] == nil { focused = nil }
    }

    // MARK: - Rename

    /// Rename a single entry. If it’s a directory, all children get their
    /// path prefixes updated too.
    func renameEntry(_ entryID: ArchiveEntry.ID, newName: String) {
        guard format?.supportsRename == true else {
            lastError = "This archive type does not support renaming."; return
        }
        guard let idx = entries.firstIndex(where: { $0.id == entryID }) else { return }
        let entry = entries[idx]
        let oldName = entry.name
        guard newName != oldName, !newName.isEmpty else { return }

        if entry.isDirectory {
            // Update the folder’s own path
            let oldPrefix = normalizedDirectoryPath(for: entry.path)
            let parentDir = entry.parentPath
            let newDirPath = parentDir.isEmpty
                ? newName + "/"
                : parentDir + "/" + newName + "/"
            entries[idx].path = newDirPath

            // Update all children whose path starts with oldPrefix
            for i in entries.indices {
                if entries[i].path.hasPrefix(oldPrefix) && entries[i].id != entryID {
                    entries[i].path = newDirPath + entries[i].path.dropFirst(oldPrefix.count)
                }
            }
        } else {
            let parentDir = entry.parentPath
            entries[idx].path = parentDir.isEmpty
                ? newName
                : parentDir + "/" + newName
        }

        isDirty = true
        buildIndices()
    }

    // MARK: - Save

    func saveArchive() {
        guard isDirty, let archiveURL else { return }
        guard let handler else { return }

        // Determine the destination. For RAR we must save as ZIP since
        // the RAR format is proprietary and we can’t create RAR files.
        let isConversion = originalFormat == .rar
        let saveURL: URL
        if isConversion {
            // Change .rar → .zip
            saveURL = archiveURL.deletingPathExtension().appendingPathExtension("zip")
        } else {
            saveURL = archiveURL
        }

        isBusy = true
        saveProgress = 0.0
        saveStatusText = "Preparing\u{2026}"
        let currentEntries = entries
        let sourceHandler = handler
        // NB: don't capture `FileManager.default` via a local `let fm` in the
        // outer scope — under Swift 6 strict concurrency that becomes a
        // non-Sendable capture when the Task.detached closure below
        // references it. Access `FileManager.default` directly inside the
        // detached closure instead.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("filesnake-save-\(UUID().uuidString)", isDirectory: true)

        do {
            try ensureEnoughDiskSpaceForSave(currentEntries: currentEntries, saveURL: saveURL)
        } catch {
            lastError = "Save failed: \(error.localizedDescription)"
            return
        }

        let box = WeakBox(self)
        Task.detached {
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: tmpDir) }

                // Step 1: Stage every file directly at its CURRENT path. This
                // collapses the old "extract-by-originalPath → rename on disk"
                // flow into a single write, which:
                //   • eliminates ghost directories left behind when a rename
                //     empties the original parent, and
                //   • guarantees the stage tree mirrors the saved archive
                //     exactly — nothing extra, nothing missing.
                let stageDir = tmpDir.appendingPathComponent("stage", isDirectory: true)
                try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)

                let fileEntries = currentEntries.filter { !$0.isDirectory }
                let totalFiles = fileEntries.count
                for (idx, entry) in fileEntries.enumerated() {
                    let name = (entry.path as NSString).lastPathComponent
                    await MainActor.run {
                        box.value?.saveProgress = totalFiles > 0
                            ? Double(idx) / Double(totalFiles) * 0.85  // extraction = 85%
                            : 0.0
                        box.value?.saveStatusText = "Saving \(idx + 1) of \(totalFiles) \u{2014} \(name)"
                    }
                    let data = try sourceHandler.extractToMemory(path: entry.originalPath)
                    let dst = stageDir.appendingPathComponent(entry.path)
                    try fm.createDirectory(
                        at: dst.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try data.write(to: dst)
                }
                await MainActor.run {
                    box.value?.saveProgress = 0.90
                    box.value?.saveStatusText = "Compressing\u{2026}"
                }

                // Step 2: Materialize every directory entry — including empty
                // ones — so `zip -r` preserves them. Without this, renaming an
                // empty folder (or any archive that contains empty folders)
                // loses those entries entirely on save.
                let dirEntries = currentEntries.filter { $0.isDirectory }
                for dir in dirEntries {
                    let target = stageDir.appendingPathComponent(dir.path, isDirectory: true)
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                }

                // Validate staging: every file AND directory entry must exist
                // before packing. Directory validation is what catches the
                // empty-folder data-loss case.
                let missingStagedFiles = fileEntries
                    .map(\.path)
                    .filter { !fm.fileExists(atPath: stageDir.appendingPathComponent($0).path) }
                guard missingStagedFiles.isEmpty else {
                    let sample = missingStagedFiles.prefix(3).joined(separator: ", ")
                    throw ArchiveError.extractFailed(
                        "Save staging mismatch: expected \(fileEntries.count) files, " +
                        "missing: \(sample)")
                }
                let missingStagedDirs: [String] = dirEntries.compactMap { dir in
                    var isDir: ObjCBool = false
                    let p = stageDir.appendingPathComponent(dir.path).path
                    let exists = fm.fileExists(atPath: p, isDirectory: &isDir)
                    return (exists && isDir.boolValue) ? nil : dir.path
                }
                guard missingStagedDirs.isEmpty else {
                    let sample = missingStagedDirs.prefix(3).joined(separator: ", ")
                    throw ArchiveError.extractFailed(
                        "Save staging mismatch: missing directories: \(sample)")
                }

                // Step 3: Create ZIP from staged folder contents using ZIPFoundation.
                // We use ZIPFoundation directly rather than `/usr/bin/zip` because
                // Apple's `/usr/bin/zip` is ancient and fails to set the UTF-8 flag
                // (bit 11) when it writes paths. This causes ZIPFoundation to later
                // decode them as CP437, breaking validation and extraction for
                // non-ASCII names. ZIPFoundation sets the UTF-8 flag automatically.
                let tmpZip = tmpDir.appendingPathComponent("__output.zip")
                let saveArchive = try Archive(url: tmpZip, accessMode: .create)
                
                // Add all files first
                for entry in fileEntries {
                    let stagedURL = stageDir.appendingPathComponent(entry.path)
                    try saveArchive.addEntry(with: entry.path, fileURL: stagedURL, compressionMethod: .none)
                }
                
                // Add explicit directory entries so empty folders are preserved
                for entry in dirEntries {
                    let dirPath = entry.path.hasSuffix("/") ? entry.path : entry.path + "/"
                    try saveArchive.addEntry(
                        with: dirPath,
                        type: .directory,
                        uncompressedSize: Int64(0),
                        compressionMethod: .none,
                        provider: { _, _ in return Data() }
                    )
                }

                // Validate ZIP payload. We check files AND directories — the
                // old file-only check allowed an empty-folder data-loss bug
                // to ship silently.
                //
                // NFC normalization: macOS HFS+ stores filenames in NFD (decomposed
                // Unicode), so `zip -r` reads NFD paths from the stage dir and
                // stores them in the new ZIP. The model paths decoded by ZIPFoundation
                // from the original archive may be NFC. The same character "é"
                // looks identical but `é`(NFC, U+00E9) ≠ `e + ́`(NFD) as strings.
                // Normalizing both sides to NFC collapses that difference.
                let archive = try Archive(url: tmpZip, accessMode: .read)
                var zipFilePaths: Set<String> = []
                var zipDirPaths: Set<String> = []
                for entry in archive {
                    var path = entry.path.precomposedStringWithCanonicalMapping
                    if path.hasPrefix("./") { path.removeFirst(2) }
                    switch entry.type {
                    case .file:      zipFilePaths.insert(path)
                    case .directory: zipDirPaths.insert(path)
                    default: break
                    }
                }
                let expectedFilePaths = Set(
                    fileEntries.map { $0.path.precomposedStringWithCanonicalMapping })
                let missingFilesInZip = expectedFilePaths.subtracting(zipFilePaths)
                guard missingFilesInZip.isEmpty else {
                    let sample = missingFilesInZip.sorted().prefix(3).joined(separator: ", ")
                    throw ArchiveError.extractFailed(
                        "Save output mismatch: missing files in zip: \(sample)")
                }
                // Any explicit directory entry from the model must appear in
                // the zip (empty folders are the failure mode this catches).
                let expectedDirPaths = Set(dirEntries.map {
                    let p = $0.path.hasSuffix("/") ? $0.path : $0.path + "/"
                    return p.precomposedStringWithCanonicalMapping
                })
                let missingDirsInZip = expectedDirPaths.subtracting(zipDirPaths)
                guard missingDirsInZip.isEmpty else {
                    let sample = missingDirsInZip.sorted().prefix(3).joined(separator: ", ")
                    throw ArchiveError.extractFailed(
                        "Save output mismatch: missing directories in zip: \(sample)")
                }

                // Step 4: Replace original file with rollback safety.
                let backupURL = tmpDir.appendingPathComponent("__original_backup")
                if fm.fileExists(atPath: backupURL.path) {
                    try? fm.removeItem(at: backupURL)
                }
                if fm.fileExists(atPath: saveURL.path) {
                    try fm.moveItem(at: saveURL, to: backupURL)
                }
                do {
                    try fm.moveItem(at: tmpZip, to: saveURL)
                    if fm.fileExists(atPath: backupURL.path) {
                        try? fm.removeItem(at: backupURL)
                    }
                } catch {
                    if fm.fileExists(atPath: backupURL.path) {
                        try? fm.moveItem(at: backupURL, to: saveURL)
                    }
                    throw error
                }

                // If we converted from RAR, remove the old .rar
                if isConversion && fm.fileExists(atPath: archiveURL.path) {
                    try fm.removeItem(at: archiveURL)
                }

                await MainActor.run {
                    guard let self = box.value else { return }
                    self.saveProgress = 1.0
                    self.saveStatusText = "Done"
                }
                // Brief pause so the user sees 100% before dismissal
                try? await Task.sleep(nanoseconds: 400_000_000)
                await MainActor.run {
                    guard let self = box.value else { return }
                    self.isBusy = false
                    self.saveProgress = nil
                    self.saveStatusText = ""
                    // Only reopen if the document is still open. If the user
                    // triggered save via the close-prompt, close() has already
                    // wiped state (archiveURL == nil) — reopening here would
                    // repopulate a detached window and tear QuickLook apart
                    // mid-teardown (the cause of the PreviewPane crash).
                    if self.archiveURL != nil {
                        self.open(url: saveURL)
                    }
                }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run {
                    box.value?.lastError = "Save failed: \(msg)"
                    box.value?.isBusy = false
                    box.value?.saveProgress = nil
                    box.value?.saveStatusText = ""
                }
            }
        }
    }

    /// Called by the app delegate when the user chooses Save in the quit dialog.
    /// Runs the full save pipeline, then tells macOS it's safe to terminate.
    /// We returned .terminateLater from applicationShouldTerminate, so macOS
    /// holds the quit until we call NSApp.reply(toApplicationShouldTerminate:).
    func saveAndThenTerminate() {
        // Run the normal save. When it completes, reply to the system.
        saveArchive()
        // Watch isBusy: when it drops back to false the save task finished.
        let box = WeakBox(self)
        Task { @MainActor in
            // Poll until save finishes (isBusy goes false = done or errored).
            while box.value?.isBusy == true {
                try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
            }
            let succeeded = box.value?.lastError == nil
            if succeeded {
                NSApp.reply(toApplicationShouldTerminate: true)
            } else {
                // Leave the app alive so the error alert is visible.
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
    }

    private func ensureEnoughDiskSpaceForSave(
        currentEntries: [ArchiveEntry],
        saveURL: URL
    ) throws {
        let estimatedStageBytes = currentEntries
            .filter { !$0.isDirectory }
            .reduce(UInt64(0)) { $0 + $1.uncompressedSize }
        // We stage extracted files and then write a new ZIP; assume near-worst-case.
        let estimatedRequired = estimatedStageBytes
            .addingReportingOverflow(estimatedStageBytes).partialValue
            .addingReportingOverflow(64 * 1024 * 1024).partialValue

        let targetDir = saveURL.deletingLastPathComponent()
        let values = try targetDir.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        )
        let available = UInt64(values.volumeAvailableCapacityForImportantUsage ??
                               Int64(values.volumeAvailableCapacity ?? 0))

        guard available >= estimatedRequired else {
            let need = Formatters.bytes(estimatedRequired)
            let have = Formatters.bytes(available)
            throw ArchiveError.extractFailed(
                "Not enough free disk space to save this archive. Need about \(need), available \(have).")
        }
    }

    /// Extract a single file entry to the preview/temp cache and return its URL.
    /// For folders, extracts all descendants and returns the folder URL.
    func materializeForOpen(_ entry: ArchiveEntry) -> URL? {
        guard let handler, let dir = previewCacheDir else { return nil }
        let fm = FileManager.default
        if entry.isDirectory {
            let prefix = normalizedDirectoryPath(for: entry.path)
            let childFiles = entries.filter { !$0.isDirectory && $0.path.hasPrefix(prefix) }
            guard !childFiles.isEmpty else {
                // Empty folder — create an empty directory to open.
                let target = dir.appendingPathComponent(entry.path, isDirectory: true)
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                return target
            }
            do {
                try handler.extract(paths: childFiles.map(\.originalPath), to: dir)
                for item in childFiles where item.path != item.originalPath {
                    let src = dir.appendingPathComponent(item.originalPath)
                    let dst = dir.appendingPathComponent(item.path)
                    guard fm.fileExists(atPath: src.path) else { continue }
                    try fm.createDirectory(
                        at: dst.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                    try fm.moveItem(at: src, to: dst)
                }
                return dir.appendingPathComponent(entry.path, isDirectory: true)
            } catch {
                lastError = error.localizedDescription
                return nil
            }
        } else {
            let target = dir.appendingPathComponent(entry.path)
            if fm.fileExists(atPath: target.path) { return target }
            do {
                try fm.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try handler.extractToMemory(path: entry.originalPath)
                let originalTarget = dir.appendingPathComponent(entry.originalPath)
                try fm.createDirectory(
                    at: originalTarget.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try data.write(to: originalTarget)
                if entry.path != entry.originalPath {
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.moveItem(at: originalTarget, to: target)
                }
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
        let fm = FileManager.default
        let target = dir.appendingPathComponent(entry.path)
        if fm.fileExists(atPath: target.path) { return target }
        do {
            try fm.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try handler.extractToMemory(path: entry.originalPath)
            let originalTarget = dir.appendingPathComponent(entry.originalPath)
            try fm.createDirectory(
                at: originalTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: originalTarget)
            if entry.path != entry.originalPath {
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.moveItem(at: originalTarget, to: target)
            }
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

    /// True for paths that are pure macOS Finder metadata noise and should
    /// be hidden from the user (and stripped on save).
    /// Covers:
    ///   • `__MACOSX/…`  — AppleDouble resource-fork sidecar tree injected
    ///     by Finder's "Compress" action.
    ///   • `._<name>`    — legacy AppleDouble sidecars.
    ///   • `.DS_Store`   — Finder view-state junk.
    ///
    /// `nonisolated` because the class is `@MainActor` and this is called
    /// from `Task.detached` in `open(url:)`. The function is pure — no
    /// instance state is touched — so there is nothing to protect.
    nonisolated static func isMacMetadataPath(_ path: String) -> Bool {
        // __MACOSX wrapper (with or without trailing slash, at root or nested
        // — nested shouldn't happen, but be defensive).
        if path == "__MACOSX" || path == "__MACOSX/" { return true }
        if path.hasPrefix("__MACOSX/") { return true }
        // Last path component checks
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let name = (trimmed as NSString).lastPathComponent
        if name == ".DS_Store" { return true }
        if name.hasPrefix("._") { return true }
        return false
    }

    private func runBusy<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T,
        thenOnMain apply: @escaping @MainActor (Result<T, Error>) -> Void
    ) {
        isBusy = true
        let box = WeakBox(self)
        Task.detached {
            do {
                let result = try work()
                await MainActor.run { apply(.success(result)); box.value?.isBusy = false }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run { box.value?.lastError = msg; box.value?.isBusy = false; box.value?.saveProgress = nil; apply(.failure(error)) }
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

// MARK: - Background Extraction

extension ArchiveDocument {
    nonisolated static func backgroundExtract(urls: [URL], dest: String, trash: Bool, appDelegate: AppDelegate? = nil) {
        Task { @MainActor in
            for url in urls {
                let doc = ArchiveDocument()
                if dest != "select" {
                    appDelegate?.document = doc
                }
                
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    doc.open(url: url) {
                        continuation.resume()
                    }
                }
                
                guard doc.handler != nil else { continue }
                
                var targetURL: URL?
                if dest == "select" {
                    NSApp.activate(ignoringOtherApps: true)
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Extract Here"
                    panel.message = "Select a destination folder"
                    if panel.runModal() == .OK, let selURL = panel.url {
                        targetURL = selURL
                    }
                } else {
                    switch dest {
                    case "desktop": targetURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
                    case "documents": targetURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                    case "downloads": targetURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                    case "here": fallthrough
                    default: targetURL = url.deletingLastPathComponent()
                    }
                }
                
                guard let finalDest = targetURL else { continue }
                
                let topLevelCount = Set(doc.entries.compactMap { $0.path.split(separator: "/").first }).count
                let finalTargetURL = topLevelCount > 1 ? finalDest.appendingPathComponent(url.deletingPathExtension().lastPathComponent) : finalDest
                
                let fileEntries = doc.entries.filter { !$0.isDirectory }
                
                if dest == "select" {
                    appDelegate?.document = doc
                    // Hide again before extraction begins
                    for window in NSApp.windows where !(window is NSPanel) {
                        window.close()
                    }
                    NSApp.hide(nil)
                }
                
                let startTime = Date()
                let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    doc.extractEntries(fileEntries, to: finalTargetURL, using: doc.handler!, completion: { ok in
                        continuation.resume(returning: ok)
                    })
                }
                
                if !success {
                    // If it failed, don't trash, and show error briefly
                    let errorMsg = doc.lastError?.lowercased() ?? ""
                    if errorMsg.contains("space") || errorMsg.contains("nospc") {
                        doc.saveStatusText = "Not enough space on the destination folder."
                    } else {
                        doc.saveStatusText = "Extraction Failed: \(doc.lastError ?? "Unknown Error")"
                    }
                    doc.saveProgress = nil
                    doc.isBusy = true // Keep panel open to show the error
                    try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s for user to read
                } else {
                    // Ensure HUD is visible for at least a short moment so it doesn't flash like a bug
                    let elapsed = Date().timeIntervalSince(startTime)
                    if elapsed < 0.6 {
                        try? await Task.sleep(nanoseconds: UInt64((0.6 - elapsed) * 1_000_000_000))
                    }
                    
                    if trash {
                        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    }
                }
            }
            if appDelegate != nil {
                // If it failed, we already waited 3s. If it succeeded, we waited 0.6s.
                // We can terminate now.
                NSApp.terminate(nil)
            }
        }
    }
    
    nonisolated static func testValidity(urls: [URL], appDelegate: AppDelegate?) {
        Task { @MainActor in
            for url in urls {
                let doc = ArchiveDocument()
                appDelegate?.document = doc
                
                doc.saveStatusText = "Verifying\u{2026}"
                doc.isBusy = true
                
                let box = WeakBox(doc)
                appDelegate?.observeSaveProgress(for: doc)
                
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    doc.open(url: url) {
                        continuation.resume()
                    }
                }
                
                guard doc.handler != nil else { continue }
                
                doc.isBusy = true
                doc.saveStatusText = "Verifying\u{2026}"
                doc.saveProgress = 0.0
                
                let filesToVerify = doc.entries.filter { !$0.isDirectory }
                let totalBytes = filesToVerify.reduce(0) { $0 + $1.uncompressedSize }
                let handler = doc.handler
                
                let verificationResult = await Task.detached {
                    var verifiedBytes: UInt64 = 0
                    do {
                        for entry in filesToVerify {
                            if Task.isCancelled { break }
                            _ = try handler?.extractToMemory(path: entry.path)
                            verifiedBytes += entry.uncompressedSize
                            
                            let currentVerified = verifiedBytes
                            await MainActor.run {
                                box.value?.saveProgress = Double(currentVerified) / Double(max(totalBytes, 1))
                                let vStr = ArchiveDocument.formatBytes(currentVerified)
                                let tStr = ArchiveDocument.formatBytes(totalBytes)
                                box.value?.saveStatusText = "Verifying\u{2026} \(vStr) of \(tStr)"
                            }
                        }
                        return true
                    } catch {
                        await MainActor.run { box.value?.lastError = error.localizedDescription }
                        return false
                    }
                }.value
                
                if verificationResult {
                    doc.saveStatusText = "No errors found"
                    doc.saveProgress = 1.0
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                
                doc.isBusy = false
                doc.saveProgress = nil
            }
            if appDelegate != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            }
        }
    }
    nonisolated static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB, .useBytes]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
    
    nonisolated static func directorySize(url: URL) -> UInt64 {
        var size: UInt64 = 0
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let attr = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]), let fileSize = attr.totalFileAllocatedSize {
                    size += UInt64(fileSize)
                }
            }
        }
        return size
    }
}
