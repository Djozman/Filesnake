import Foundation
import SWCompression

final class GzipHandler: ArchiveHandler, @unchecked Sendable {
    let format: ArchiveFormat = .gz
    let url: URL

    init(url: URL) throws {
        self.url = url
    }

    func list() throws -> [ArchiveEntry] {
        let raw = try Data(contentsOf: url)
        let inner = try GzipArchive.multiUnarchive(archive: raw).first
        let name = innerName()
        let size = UInt64(inner?.data.count ?? 0)
        return [ArchiveEntry(
            path: name,
            isDirectory: false,
            uncompressedSize: size,
            compressedSize: UInt64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0),
            modified: inner?.header.modificationTime,
            crc32: nil
        )]
    }

    func extract(paths: [String], to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let raw = try Data(contentsOf: url)
        let data = try GzipArchive.unarchive(archive: raw)
        try data.write(to: destination.appendingPathComponent(innerName()))
    }

    func extractToMemory(path: String) throws -> Data {
        let raw = try Data(contentsOf: url)
        return try GzipArchive.unarchive(archive: raw)
    }

    private func innerName() -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? "decompressed" : name
    }
}
