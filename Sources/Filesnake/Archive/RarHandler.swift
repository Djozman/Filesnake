import Foundation

final class RarHandler: ArchiveHandler, @unchecked Sendable {
    let format: ArchiveFormat = .rar
    let url: URL

    init(url: URL) throws {
        self.url = url
        // Verify lsar can open the file
        let lsar = try Self.lsarPath()
        _ = try Self.runToolAt(path: lsar, args: [url.path])
    }

    func list() throws -> [ArchiveEntry] {
        let lsar = try Self.lsarPath()
        let output = try Self.runToolAt(path: lsar, args: [url.path])
        return RarHandler.parseLsarOutput(output: output)
    }

    func extract(paths: [String], to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let unar = try Self.unarPath()
        // Use -D to prevent unar from creating a containing subdirectory,
        // and pass all paths in one call so everything extracts into the same folder.
        try Self.runToolAt(path: unar, args: ["-D", "-o", destination.path, url.path] + paths)
    }

    func extractToMemory(path: String) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try extract(paths: [path], to: tmp)
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: tmp, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue {
                    return try Data(contentsOf: fileURL)
                }
            }
        }
        throw ArchiveError.notFound("Could not locate extracted file for: \(path)")
    }

    // MARK: - Tool paths

    private static func unarPath() throws -> String {
        let candidates = ["/opt/homebrew/bin/unar", "/usr/local/bin/unar"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw ArchiveError.unsupported(
            "RAR support requires 'unar'. Install via Homebrew: brew install unar"
        )
    }

    private static func lsarPath() throws -> String {
        let candidates = ["/opt/homebrew/bin/lsar", "/usr/local/bin/lsar"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw ArchiveError.unsupported(
            "RAR support requires 'lsar'. Install via Homebrew: brew install unar"
        )
    }

    // MARK: - Run process

    @discardableResult
    private static func runToolAt(path: String, args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            throw ArchiveError.extractFailed("Failed to launch \(path): \(error.localizedDescription)")
        }
        proc.waitUntilExit()
        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard proc.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ArchiveError.extractFailed(
                "\(URL(fileURLWithPath: path).lastPathComponent) exited \(proc.terminationStatus): \(err)"
            )
        }
        return output
    }

    // MARK: - Parse lsar output
    // lsar prints one path per line; the first line is "<archive>: <type>"

    private static func parseLsarOutput(output: String) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        let lines = output.components(separatedBy: "\n")
        for (i, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // Skip the first line which is "<path>: <format>"
            if i == 0 && line.contains(": ") { continue }
            let isDir = line.hasSuffix("/")
            entries.append(ArchiveEntry(
                path: line,
                isDirectory: isDir,
                uncompressedSize: 0,
                compressedSize: 0,
                modified: nil,
                crc32: nil
            ))
        }
        return entries
    }
}
