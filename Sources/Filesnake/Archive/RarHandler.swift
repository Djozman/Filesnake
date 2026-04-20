import Foundation

final class RarHandler: ArchiveHandler {
    let format: ArchiveFormat = .rar
    let url: URL

    init(url: URL) throws {
        self.url = url
    }

    func list() throws -> [ArchiveEntry] {
        throw ArchiveError.unsupported(
            "RAR support is not yet implemented. Planned for v0.2 via UnrarKit. " +
            "As a workaround, run: `unar \"\(url.path)\"` in Terminal."
        )
    }

    func extract(paths: [String], to destination: URL) throws {
        throw ArchiveError.unsupported("RAR extraction not yet implemented.")
    }

    func extractToMemory(path: String) throws -> Data {
        throw ArchiveError.unsupported("RAR preview not yet implemented.")
    }
}
