import Foundation

struct ArchiveEntry: Identifiable, Hashable {
    let id = UUID()
    /// Current path (may differ from `originalPath` after a rename).
    var path: String
    let isDirectory: Bool
    let uncompressedSize: UInt64
    let compressedSize: UInt64
    let modified: Date?
    let crc32: UInt32?
    /// The path as it exists on disk inside the archive. Stays fixed even
    /// after renames so we know which entry to extract during save.
    let originalPath: String

    init(path: String, isDirectory: Bool, uncompressedSize: UInt64,
         compressedSize: UInt64, modified: Date?, crc32: UInt32?,
         originalPath: String? = nil) {
        self.path = path
        self.isDirectory = isDirectory
        self.uncompressedSize = uncompressedSize
        self.compressedSize = compressedSize
        self.modified = modified
        self.crc32 = crc32
        self.originalPath = originalPath ?? path
    }

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
