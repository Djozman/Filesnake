import Foundation

final class RarHandler: ArchiveHandler {
    let format: ArchiveFormat = .rar
    let url: URL

    init(url: URL) throws {
        self.url = url
        let tool = try Self.toolPath()
        if tool.hasSuffix("unar") {
            _ = try Self.runToolAt(path: tool, args: ["-l", url.path])
        } else {
            _ = try Self.runToolAt(path: tool, args: ["l", url.path])
        }
    }

    func list() throws -> [ArchiveEntry] {
        let tool = try Self.toolPath()
        let output: String
        if tool.hasSuffix("unar") {
            output = try Self.runToolAt(path: tool, args: ["-l", url.path])
            return RarHandler.parseUnarList(output: output)
        } else {
            output = try Self.runToolAt(path: tool, args: ["l", "-v", url.path])
            return RarHandler.parseUnrarList(output: output)
        }
    }

    func extract(paths: [String], to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let tool = try Self.toolPath()
        let isUnar = tool.hasSuffix("unar")
        for path in paths {
            let args: [String]
            if isUnar {
                args = ["-o", destination.path, url.path, path]
            } else {
                args = ["x", "-y", url.path, path, destination.path + "/"]
            }
            try Self.runToolAt(path: tool, args: args)
        }
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

    private static func toolPath() throws -> String {
        let candidates = [
            "/opt/homebrew/bin/unar",
            "/usr/local/bin/unar",
            "/opt/homebrew/bin/unrar",
            "/usr/local/bin/unrar",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw ArchiveError.unsupported(
            "RAR support requires 'unar' or 'unrar'. " +
            "Install via Homebrew: brew install unar"
        )
    }

    private static func parseUnrarList(output: String) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        let lines = output.components(separatedBy: "\n")
        var inBody = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && trimmed.allSatisfy({ $0 == "-" }) && trimmed.count > 10 {
                inBody.toggle()
                continue
            }
            guard inBody, !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 5 else { continue }
            let attrs = String(parts[0])
            let isDir = attrs.contains("D")
            let uncompressedSize = UInt64(String(parts[1])) ?? 0
            let path = parts.last.map(String.init) ?? ""
            guard !path.isEmpty else { continue }
            entries.append(ArchiveEntry(
                path: isDir ? (path.hasSuffix("/") ? path : path + "/") : path,
                isDirectory: isDir,
                uncompressedSize: uncompressedSize,
                compressedSize: 0,
                modified: nil,
                crc32: nil
            ))
        }
        return entries
    }

    private static func parseUnarList(output: String) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        let lines = output.components(separatedBy: "\n")

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard !line.hasPrefix("UNAR "),
                  !line.hasPrefix("Archive:"),
                  !line.hasPrefix("Details:"),
                  !line.hasPrefix("  "),
                  !line.hasPrefix("Extracting") else { continue }

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
