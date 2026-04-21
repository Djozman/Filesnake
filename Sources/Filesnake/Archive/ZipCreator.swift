import Foundation
import ZIPFoundation

/// Creates a new ZIP archive from a list of files / directories.
enum ZipCreator {

    /// Creates a ZIP at `destination` containing the given file/directory URLs.
    /// Directories are added recursively.
    static func createZip(at destination: URL, from sources: [URL]) throws {
        // Remove existing file if needed
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }

        let archive: Archive
        do {
            archive = try Archive(url: destination, accessMode: .create)
        } catch {
            throw ArchiveError.extractFailed("Could not create ZIP at \(destination.path): \(error.localizedDescription)")
        }

        for source in sources {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                // Add directory contents recursively
                try addDirectory(source, to: archive, basePath: source.deletingLastPathComponent().path)
            } else {
                // Add single file
                let relativePath = source.lastPathComponent
                try archive.addEntry(
                    with: relativePath,
                    fileURL: source,
                    compressionMethod: .deflate
                )
            }
        }
    }

    private static func addDirectory(_ dirURL: URL, to archive: Archive, basePath: String) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dirURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        // Add the directory entry itself
        let dirRelative = String(dirURL.path.dropFirst(basePath.count + 1)) + "/"
        try archive.addEntry(
            with: dirRelative,
            type: .directory,
            uncompressedSize: Int64(0),
            provider: { _, _ in Data() }
        )

        for case let fileURL as URL in enumerator {
            let relativePath = String(fileURL.path.dropFirst(basePath.count + 1))
            var isDirectory: ObjCBool = false
            fm.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)

            if isDirectory.boolValue {
                try archive.addEntry(
                    with: relativePath + "/",
                    type: .directory,
                    uncompressedSize: Int64(0),
                    provider: { _, _ in Data() }
                )
            } else {
                try archive.addEntry(
                    with: relativePath,
                    fileURL: fileURL,
                    compressionMethod: .deflate
                )
            }
        }
    }
}
