import Foundation

struct ArchiveEntry: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let isDirectory: Bool
    let uncompressedSize: UInt64
    let compressedSize: UInt64
    let modified: Date?
    let crc32: UInt32?

    var name: String {
        (path as NSString).lastPathComponent
    }

    var parentPath: String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let ns = trimmed as NSString
        let parent = ns.deletingLastPathComponent
        return parent
    }

    var pathExtension: String {
        (path as NSString).pathExtension.lowercased()
    }

    var compressionRatio: Double {
        guard uncompressedSize > 0 else { return 0 }
        return 1.0 - (Double(compressedSize) / Double(uncompressedSize))
    }
}
