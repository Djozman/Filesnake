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

    private var handler: ArchiveHandler?
    private var previewCacheDir: URL?

    var filteredEntries: [ArchiveEntry] {
        guard !searchText.isEmpty else { return entries }
        let q = searchText.lowercased()
        return entries.filter { $0.path.lowercased().contains(q) }
    }

    var checkedEntries: [ArchiveEntry] {
        entries.filter { checked.contains($0.id) }
    }

    var currentEntry: ArchiveEntry? {
        guard let id = focused else { return nil }
        return entries.first { $0.id == id }
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
        runBusy({
            try handler.extract(paths: paths, to: dest)
        }, thenOnMain: {
            NSWorkspace.shared.open(dest)
        })
    }

    func extractAll() {
        guard let handler else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Extract Here"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let paths = entries.filter { !$0.isDirectory }.map { $0.path }
        runBusy({
            try handler.extract(paths: paths, to: dest)
        }, thenOnMain: {
            NSWorkspace.shared.open(dest)
        })
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

    private func runBusy<T>(
        _ work: @escaping () throws -> T,
        thenOnMain apply: @escaping (T) -> Void
    ) {
        isBusy = true
        Task.detached { [weak self] in
            do {
                let result = try work()
                await MainActor.run {
                    apply(result)
                    self?.isBusy = false
                }
            } catch {
                await MainActor.run {
                    self?.lastError = error.localizedDescription
                    self?.isBusy = false
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
        if let dir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}
