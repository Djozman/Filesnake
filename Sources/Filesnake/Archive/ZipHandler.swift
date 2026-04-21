import Foundation
import ZIPFoundation

final class ZipHandler: ArchiveHandler {
    let format: ArchiveFormat = .zip
    let url: URL

    init(url: URL) throws {
        self.url = url
        _ = try openArchive(mode: .read)
    }

    func list() throws -> [ArchiveEntry] {
        let archive = try openArchive(mode: .read)
        var entries: [ArchiveEntry] = []
        for entry in archive {
            let isDir = entry.type == .directory
            entries.append(ArchiveEntry(
                path: entry.path,
                isDirectory: isDir,
                uncompressedSize: UInt64(entry.uncompressedSize),
                compressedSize: UInt64(entry.compressedSize),
                modified: entry.fileAttributes[.modificationDate] as? Date,
                crc32: entry.checksum
            ))
        }
        return entries
    }

    func extract(paths: [String], to destination: URL) throws {
        let archive = try openArchive(mode: .read)
        let wanted = Set(paths)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for entry in archive where wanted.contains(entry.path) {
            let target = destination.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try archive.extract(entry, to: target)
        }
    }

    func extractToMemory(path: String) throws -> Data {
        let archive = try openArchive(mode: .read)
        guard let entry = archive[path] else {
            throw ArchiveError.notFound("Entry not found: \(path)")
        }
        var data = Data()
        _ = try archive.extract(entry) { chunk in
            data.append(chunk)
        }
        return data
    }

    func delete(paths: [String]) throws {
        let archive = try openArchive(mode: .update)
        for path in paths {
            guard let entry = archive[path] else { continue }
            try archive.remove(entry)
        }
    }

    private func openArchive(mode: Archive.AccessMode) throws -> Archive {
        do {
            return try Archive(url: url, accessMode: mode)
        } catch {
            throw ArchiveError.readFailed("Could not open ZIP: \(error.localizedDescription)")
        }
    }

    /// Create a fresh ZIP at `destination` by packing each `relativePaths`
    /// entry from `root`. Destination is overwritten if it already exists.
    /// Missing files are skipped rather than failing the whole archive.
    static func create(at destination: URL, root: URL, relativePaths: [String]) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        let archive: Archive
        do {
            archive = try Archive(url: destination, accessMode: .create)
        } catch {
            throw ArchiveError.extractFailed(
                "Could not create ZIP at \(destination.path): \(error.localizedDescription)"
            )
        }
        for rel in relativePaths {
            let source = root.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }
            do {
                try archive.addEntry(with: rel, relativeTo: root, compressionMethod: .deflate)
            } catch {
                throw ArchiveError.extractFailed(
                    "Failed adding \(rel) to new ZIP: \(error.localizedDescription)"
                )
            }
        }
    }
}
