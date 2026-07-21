import Foundation

final class RarHandler: ArchiveHandler, @unchecked Sendable {
    let format: ArchiveFormat = .rar
    let url: URL

    init(url: URL) throws {
        self.url = url
        let lsar = try Self.lsarPath()
        _ = try Self.runToolAt(path: lsar, args: ["-json", url.path])
    }

    func list() throws -> [ArchiveEntry] {
        let lsar = try Self.lsarPath()
        let output = try Self.runToolAt(path: lsar, args: ["-json", url.path])
        return try Self.parseLsarJSON(output)
    }

    func extract(paths: [String], to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let unar = try Self.unarPath()
        try Self.runToolAt(path: unar, args: ["-D", "-o", destination.path, url.path] + paths)
    }

    func extractToMemory(path: String) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try extract(paths: [path], to: tmp)
        let target = tmp.appendingPathComponent(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw ArchiveError.notFound("Could not locate extracted file for: \(path)")
        }
        return try Data(contentsOf: target)
    }

    private static func unarPath() throws -> String {
        try toolPath(named: "unar")
    }

    private static func lsarPath() throws -> String {
        try toolPath(named: "lsar")
    }

    private static func toolPath(named name: String) throws -> String {
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw ArchiveError.unsupported(
            "RAR support requires '\(name)'. Install via Homebrew: brew install unar"
        )
    }

    @discardableResult
    private static func runToolAt(path: String, args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw ArchiveError.extractFailed(
                "Failed to launch \(URL(fileURLWithPath: path).lastPathComponent): \(error.localizedDescription)"
            )
        }

        // Reading to EOF drains the pipe while the child is running. Waiting
        // first can deadlock on archives with a large lsar listing.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw ArchiveError.extractFailed(
                "\(URL(fileURLWithPath: path).lastPathComponent) exited \(process.terminationStatus): \(text)"
            )
        }
        return text
    }

    private static func parseLsarJSON(_ output: String) throws -> [ArchiveEntry] {
        guard let data = output.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contents = root["lsarContents"] as? [[String: Any]] else {
            throw ArchiveError.readFailed("Could not parse lsar archive metadata.")
        }

        let isoFormatter = ISO8601DateFormatter()
        return contents.compactMap { item in
            guard let path = item["XADFileName"] as? String, !path.isEmpty else { return nil }
            let isDirectory = (item["XADIsDirectory"] as? Bool) ?? path.hasSuffix("/")
            let size = unsignedValue(item["XADFileSize"])
            let compressed = unsignedValue(item["XADCompressedSize"])
            let date = (item["XADLastModificationDate"] as? String).flatMap(isoFormatter.date(from:))
            return ArchiveEntry(
                path: path,
                isDirectory: isDirectory,
                uncompressedSize: size,
                compressedSize: compressed,
                modified: date,
                crc32: nil
            )
        }
    }

    private static func unsignedValue(_ value: Any?) -> UInt64 {
        if let number = value as? NSNumber { return number.uint64Value }
        if let string = value as? String, let number = UInt64(string) { return number }
        return 0
    }
}
