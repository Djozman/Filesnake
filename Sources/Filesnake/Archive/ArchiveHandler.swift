import Foundation

protocol ArchiveHandler: Sendable {
    var format: ArchiveFormat { get }
    var url: URL { get }

    func list() throws -> [ArchiveEntry]
    func extract(paths: [String], to destination: URL) throws
    func extractToMemory(path: String) throws -> Data
    func delete(paths: [String]) throws
}

extension ArchiveHandler {
    func delete(paths: [String]) throws {
        throw ArchiveError.unsupported("Deletion not supported for \(format.displayName).")
    }
}

enum ArchiveError: LocalizedError {
    case unsupported(String)
    case notFound(String)
    case readFailed(String)
    case extractFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let s), .notFound(let s), .readFailed(let s), .extractFailed(let s):
            return s
        }
    }
}

enum ArchiveHandlerFactory {
    static func make(url: URL) throws -> ArchiveHandler {
        guard let fmt = ArchiveFormat.detect(url: url) else {
            throw ArchiveError.unsupported("Unrecognized archive format for \(url.lastPathComponent).")
        }
        switch fmt {
        case .zip:   return try ZipHandler(url: url)
        case .tar:   return try TarHandler(url: url, gzipped: false)
        case .tarGz: return try TarHandler(url: url, gzipped: true)
        case .gz:    return try GzipHandler(url: url)
        case .rar:   return try RarHandler(url: url)
        }
    }
}
