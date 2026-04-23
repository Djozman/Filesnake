import Foundation
import SWCompression

final class TarHandler: ArchiveHandler, @unchecked Sendable {
    var format: ArchiveFormat { gzipped ? .tarGz : .tar }
    let url: URL
    private let gzipped: Bool

    init(url: URL, gzipped: Bool) throws {
        self.url = url
        self.gzipped = gzipped
        _ = try loadEntries()
    }

    func list() throws -> [ArchiveEntry] {
        try loadEntries().map { entry in
            let size = UInt64(max(entry.info.size ?? 0, 0))
            return ArchiveEntry(
                path: entry.info.name,
                isDirectory: entry.info.type == .directory,
                uncompressedSize: size,
                compressedSize: size,
                modified: entry.info.modificationTime,
                crc32: nil
            )
        }
    }

    func extract(paths: [String], to destination: URL) throws {
        let wanted = Set(paths)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for entry in try loadEntries() where wanted.contains(entry.info.name) {
            let target = destination.appendingPathComponent(entry.info.name)
            if entry.info.type == .directory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try (entry.data ?? Data()).write(to: target)
        }
    }

    func extractToMemory(path: String) throws -> Data {
        guard let entry = try loadEntries().first(where: { $0.info.name == path }) else {
            throw ArchiveError.notFound("Entry not found: \(path)")
        }
        return entry.data ?? Data()
    }

    func delete(paths: [String]) throws {
        let toDelete = Set(paths)
        let remaining = try loadEntries().filter { !toDelete.contains($0.info.name) }
        var tarData = TarContainer.create(from: remaining)
        if gzipped {
            tarData = try GzipArchive.archive(data: tarData)
        }
        // Write to a temp file beside the original, then atomically replace
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(UUID().uuidString + url.lastPathComponent)
        do {
            try tarData.write(to: tmp)
            try FileManager.default.replaceItem(at: url, withItemAt: tmp, backupItemName: nil, resultingItemURL: nil)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw ArchiveError.extractFailed("Failed to rewrite archive: \(error.localizedDescription)")
        }
    }

    private func loadEntries() throws -> [TarEntry] {
        let raw = try Data(contentsOf: url)
        let tarData: Data = gzipped ? try GzipArchive.unarchive(archive: raw) : raw
        do {
            return try TarContainer.open(container: tarData)
        } catch {
            throw ArchiveError.readFailed("Could not read TAR: \(error.localizedDescription)")
        }
    }
}
