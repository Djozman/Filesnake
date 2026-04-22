import Foundation
import ZIPFoundation

/// Creates a new ZIP archive from a list of files / directories.
enum ZipCreator {

    /// Creates a ZIP at `destination` containing the given file/directory URLs.
    /// Directories are traversed recursively; only regular files are added.
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
                try addFilesRecursively(from: source, to: archive, basePath: source.deletingLastPathComponent().path)
            } else {
                try archive.addEntry(
                    with: source.lastPathComponent,
                    fileURL: source,
                    compressionMethod: .deflate
                )
            }
        }
    }

    private static func addFilesRecursively(from dirURL: URL, to archive: Archive, basePath: String) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dirURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relativePath = String(fileURL.path.dropFirst(basePath.count + 1))
            try archive.addEntry(
                with: relativePath,
                fileURL: fileURL,
                compressionMethod: .deflate
            )
        }
    }
}
