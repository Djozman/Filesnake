import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ArchiveDocument: ObservableObject {
    @Published private(set) var archiveURL: URL?
    @Published private(set) var format: ArchiveFormat?
    @Published private(set) var entries: [ArchiveEntry] = []
    @Published var checked: Set<ArchiveEntry.ID> = []
    @Published var focused: ArchiveEntry.ID?
    @Published var searchText: String = ""
    @Published private(set) var isBusy: Bool = false
    @Published var lastError: String?
    @Published private(set) var currentFolderPath: String = ""
    @Published var sortKey: SortKey = .name
    @Published var sortAscending: Bool = true

    enum SortKey: String {
        case name, size, compressed, modified
    }

    private var handler: ArchiveHandler?
    private var previewCacheDir: URL?
    /// Lazily built cache: directory path prefix -> recursive uncompressed size
    private var folderSizeCache: [String: UInt64] = [:]
    private var folderCompressedSizeCache: [String: UInt64] = [:]

    // MARK: - Computed lists

    var visibleEntries: [ArchiveEntry] {
        let prefix = currentFolderPath
        let filtered = entries.filter { entry in
            if prefix.isEmpty {
                return !entry.path.isEmpty && !entry.parentPath.isEmpty
                    ? entry.parentPath.isEmpty
                    : !entry.path
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        .contains("/")
            }
            guard entry.path.hasPrefix(prefix) else { return false }
            let remainder = String(entry.path.dropFirst(prefix.count))
            guard !remainder.isEmpty else { return false }
            let trimmed = remainder.hasSuffix("/") ? String(remainder.dropLast()) : remainder
            return !trimmed.contains("/")
        }
        return sortEntries(filtered)
    }

    var filteredEntries: [ArchiveEntry] {
        guard !searchText.isEmpty else { return visibleEntries }
        let q = searchText.lowercased()
        return visibleEntries.filter {
            $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q)
        }
    }

    var checkedEntries: [ArchiveEntry] {
        entries.filter { checked.contains($0.id) }
    }

    var currentEntry: ArchiveEntry? {
        guard let id = focused else { return nil }
        return entries.first { $0.id == id }
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

    func toggleChecked(_ id: ArchiveEntry.ID) {
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
    }

    func checkAllVisible() {
        for e in filteredEntries { checked.insert(e.id) }
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
        close()
        isBusy = true
        defer { isBusy = false }
        do {
            let handler = try ArchiveHandlerFactory.make(url: url)
            let items = try handler.list()
            self.handler = handler
            self.archiveURL = url
            self.format = handler.format
            self.entries = items
            self.checked = []
            self.focused = nil
            self.searchText = ""
            self.currentFolderPath = ""
            self.folderSizeCache = [:]
            self.folderCompressedSizeCache = [:]
            self.previewCacheDir = makePreviewCacheDir(for: url)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func close() {
        handler = nil; archiveURL = nil; format = nil
        entries = []; checked = []; focused = nil
        searchText = ""; currentFolderPath = ""
        folderSizeCache = [:]; folderCompressedSizeCache = [:]
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
        guard let handler, let format, !checked.isEmpty else { return }
        if format.supportsDeletion {
            deleteInPlace(handler: handler)
        } else if format.supportsRepackageAsZIP {
            repackageRemovingSelectionAsZIP(handler: handler, sourceFormat: format)
        } else {
            lastError = "This archive type does not support deletion."
        }
    }

    private func deleteInPlace(handler: ArchiveHandler) {
        let paths = checkedEntries.map { $0.path }
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
            self.checked = self.checked.filter { id in newEntries.contains { $0.id == id } }
            if let f = self.focused, !newEntries.contains(where: { $0.id == f }) { self.focused = nil }
        })
    }

    /// For read-only formats (e.g. RAR): extract everything the user didn't check,
    /// repackage it as a brand-new ZIP at a user-chosen location, and open that.
    /// The original archive is never modified.
    private func repackageRemovingSelectionAsZIP(handler: ArchiveHandler, sourceFormat: ArchiveFormat) {
        guard let sourceURL = archiveURL else { return }

        let removedIDs = expandedDeletionSet()
        let survivors = entries.filter { !removedIDs.contains($0.id) && !$0.isDirectory }
        let removedCount = checkedEntries.count

        guard !survivors.isEmpty else {
            lastError = "Removing the checked entries would leave the archive empty. Aborted."
            return
        }

        let confirm = NSAlert()
        confirm.messageText = "Remove \(removedCount) entry(ies) and save as ZIP?"
        confirm.informativeText = "\(sourceFormat.displayName) archives can't be edited in place. "
            + "Filesnake will extract everything else and save a new ZIP. The original "
            + sourceURL.lastPathComponent + " will not be modified."
        confirm.addButton(withTitle: "Save As\u{2026}")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + "-edited.zip"
        panel.message = "Save edited archive as ZIP"
        guard panel.runModal() == .OK, var destURL = panel.url else { return }
        if destURL.pathExtension.lowercased() != "zip" {
            destURL = destURL.appendingPathExtension("zip")
        }
        guard destURL.standardizedFileURL != sourceURL.standardizedFileURL else {
            lastError = "Refusing to overwrite the original archive. Choose a different path."
            return
        }

        let survivorPaths = survivors.map { $0.path }
        runBusy({
            let fm = FileManager.default
            let temp = fm.temporaryDirectory
                .appendingPathComponent("Filesnake-repack-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: temp) }

            try handler.extract(paths: survivorPaths, to: temp)
            try ZipHandler.create(at: destURL, root: temp, relativePaths: survivorPaths)
            return destURL
        }, thenOnMain: { [weak self] newURL in
            self?.open(url: newURL)
        })
    }

    /// If a directory is checked, treat every descendant as also-removed.
    private func expandedDeletionSet() -> Set<ArchiveEntry.ID> {
        var ids: Set<ArchiveEntry.ID> = []
        for e in checkedEntries {
            ids.insert(e.id)
            guard e.isDirectory else { continue }
            let prefix = e.path.hasSuffix("/") ? e.path : e.path + "/"
            for child in entries where child.path.hasPrefix(prefix) {
                ids.insert(child.id)
            }
        }
        return ids
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
