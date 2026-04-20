import Foundation
import AppKit
import SwiftUI

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

    var visibleEntries: [ArchiveEntry] {
        let prefix = currentFolderPath
        let filtered = entries.filter { entry in
            if prefix.isEmpty {
                return !entry.path.isEmpty && !entry.parentPath.isEmpty
                    ? entry.parentPath.isEmpty
                    : !entry.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).contains("/")
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
        let trimmed = currentFolderPath.hasSuffix("/") ? String(currentFolderPath.dropLast()) : currentFolderPath
        return trimmed.split(separator: "/").map(String.init)
    }

    func toggleChecked(_ id: ArchiveEntry.ID) {
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
    }

    func checkAllVisible() {
        for e in filteredEntries { checked.insert(e.id) }
    }

    func uncheckAll() {
        checked.removeAll()
    }

    func enterFolder(_ entry: ArchiveEntry) {
        guard entry.isDirectory else { return }
        currentFolderPath = normalizedDirectoryPath(for: entry.path)
        focused = nil
    }

    func goBack() {
        guard !currentFolderPath.isEmpty else { return }
        let trimmed = currentFolderPath.hasSuffix("/") ? String(currentFolderPath.dropLast()) : currentFolderPath
        let parent = (trimmed as NSString).deletingLastPathComponent
        currentFolderPath = parent.isEmpty ? "" : parent + "/"
        focused = nil
    }

    func goToRoot() {
        currentFolderPath = ""
        focused = nil
    }

    func goToBreadcrumb(index: Int) {
        guard index >= 0 else { goToRoot(); return }
        let parts = breadcrumbs
        guard index < parts.count else { return }
        currentFolderPath = parts.prefix(index + 1).joined(separator: "/") + "/"
        focused = nil
    }

    func toggleSort(key: SortKey) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = true
        }
    }

    var stats: (count: Int, totalSize: UInt64) {
        let files = entries.filter { !$0.isDirectory }
        let total = files.reduce(UInt64(0)) { $0 + $1.uncompressedSize }
        return (files.count, total)
    }

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
            self.previewCacheDir = makePreviewCacheDir(for: url)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func close() {
        handler = nil
        archiveURL = nil
        format = nil
        entries = []
        checked = []
        focused = nil
        searchText = ""
        currentFolderPath = ""
        if let dir = previewCacheDir {
            try? FileManager.default.removeItem(at: dir)
        }
        previewCacheDir = nil
    }

    func extractSelection() {
        guard let handler, !checked.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Extract Here"
        panel.message = "Choose a destination folder"
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
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Extract Here"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let paths = entries.filter { !$0.isDirectory }.map { $0.path }
        runBusy({ try handler.extract(paths: paths, to: dest) },
                thenOnMain: { NSWorkspace.shared.open(dest) })
    }

    func deleteSelection() {
        guard let handler, format?.supportsDeletion == true else {
            lastError = "This archive type does not support deletion."
            return
        }
        let paths = checkedEntries.map { $0.path }
        let prompt = NSAlert()
        prompt.messageText = "Delete \(paths.count) entry(ies) from archive?"
        prompt.informativeText = "This rewrites the archive and cannot be undone."
        prompt.addButton(withTitle: "Delete")
        prompt.addButton(withTitle: "Cancel")
        guard prompt.runModal() == .alertFirstButtonReturn else { return }
        runBusy({
            try handler.delete(paths: paths)
            return try handler.list()
        }, thenOnMain: { [weak self] newEntries in
            guard let self else { return }
            self.entries = newEntries
            self.checked = self.checked.filter { id in newEntries.contains { $0.id == id } }
            if let f = self.focused, !newEntries.contains(where: { $0.id == f }) {
                self.focused = nil
            }
        })
    }

    func materializeForPreview(_ entry: ArchiveEntry) -> URL? {
        guard let handler, let dir = previewCacheDir, !entry.isDirectory else { return nil }
        let target = dir.appendingPathComponent(entry.path)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try handler.extractToMemory(path: entry.path)
            try data.write(to: target)
            return target
        } catch {
            lastError = error.localizedDescription
            return nil
        }
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
                return asc ? a.uncompressedSize < b.uncompressedSize : a.uncompressedSize > b.uncompressedSize
            case .compressed:
                return asc ? a.compressedSize < b.compressedSize : a.compressedSize > b.compressedSize
            case .modified:
                let ad = a.modified ?? .distantPast
                let bd = b.modified ?? .distantPast
                return asc ? ad < bd : ad > bd
            }
        }
    }

    private func normalizedDirectoryPath(for path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    // MARK: - runBusy (Swift 6 safe)
    //
    // Capture `self` as a local `ObjectIdentifier`-keyed weak ref so the
    // Task.detached closure only holds a Sendable `ID` value, not `var self`.

    private func runBusy<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T,
        thenOnMain apply: @escaping @MainActor (T) -> Void
    ) {
        isBusy = true
        // Capture a weak actor reference safely via a Sendable box.
        let box = WeakBox(self)
        Task.detached {
            do {
                let result = try work()
                await MainActor.run {
                    apply(result)
                    box.value?.isBusy = false
                }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run {
                    box.value?.lastError = msg
                    box.value?.isBusy = false
                }
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
