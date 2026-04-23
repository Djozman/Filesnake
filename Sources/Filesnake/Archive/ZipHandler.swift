import Foundation
import ZIPFoundation

final class ZipHandler: ArchiveHandler, @unchecked Sendable {
    let format: ArchiveFormat = .zip
    let url: URL

    /// Memoized result of `isProblematicArchive`. First extract scans the
    /// central directory once; subsequent extracts reuse the answer. Nil
    /// until the first scan completes. Guarded by `cacheLock` so concurrent
    /// extracts (rare, but possible via drag-out) race safely.
    private var cachedIsProblematic: Bool?
    /// Memoized file-count for the threshold decision in `extractViaDitto`.
    private var cachedFileCount: Int?
    private let cacheLock = NSLock()

    init(url: URL) throws {
        self.url = url
        _ = try openArchive(mode: .read)
    }

    func list() throws -> [ArchiveEntry] {
        let archive = try openArchive(mode: .read)
        var entries: [ArchiveEntry] = []
        var needsSizeFallback = false
        for entry in archive {
            let isDir = entry.type == .directory
            let u = entry.uncompressedSize
            let c = entry.compressedSize
            // ZIPFoundation 0.9.20 has a cluster of ZIP64 size-reading bugs
            // that surface on archives with files >4 GB (common for .mov):
            //   • If ZIP64 extended info is missing/malformed, the public
            //     getter returns the 0xFFFFFFFF sentinel (≈4 GB) verbatim.
            //   • If the entry uses a data descriptor, the iterator seeks
            //     past the compressed payload by the *central dir* size;
            //     when that size is the sentinel, the descriptor read lands
            //     in random bytes and yields absurd UInt64 values that
            //     render as PB/TB.
            // We detect either failure mode here and fall back to `unzip`,
            // which handles ZIP64 correctly.
            if ZipHandler.isSuspiciousSize(u) || ZipHandler.isSuspiciousSize(c) {
                needsSizeFallback = true
            }
            entries.append(ArchiveEntry(
                path: entry.path,
                isDirectory: isDir,
                uncompressedSize: u,
                compressedSize: c,
                modified: entry.fileAttributes[.modificationDate] as? Date,
                crc32: entry.checksum
            ))
        }
        if needsSizeFallback {
            let sizeMap = readSizesViaFallback()
            if !sizeMap.isEmpty {
                entries = entries.map { e in
                    let key = ZipHandler.normalizeZipPath(e.path)
                    guard let corrected = sizeMap[key] else { return e }
                    let u = ZipHandler.isSuspiciousSize(e.uncompressedSize)
                        ? corrected.uncompressed : e.uncompressedSize
                    let c = ZipHandler.isSuspiciousSize(e.compressedSize)
                        ? corrected.compressed : e.compressedSize
                    return ArchiveEntry(
                        path: e.path,
                        isDirectory: e.isDirectory,
                        uncompressedSize: u,
                        compressedSize: c,
                        modified: e.modified,
                        crc32: e.crc32,
                        originalPath: e.originalPath
                    )
                }
            }
        }
        return entries
    }

    /// A size is "suspicious" if it's either the 4 GB ZIP64 sentinel
    /// (0xFFFFFFFF) or so large it can't possibly be a real file entry.
    /// 1 PiB is our sanity ceiling — no legitimate .mov or any single
    /// archive member is that big in 2026.
    private static func isSuspiciousSize(_ size: UInt64) -> Bool {
        if size == 0xFFFFFFFF { return true }          // ZIP64 sentinel
        if size > (UInt64(1) << 50) { return true }    // > 1 PiB → garbage
        return false
    }

    /// Normalize a zip entry path the same way we compare against entries
    /// listed via `unzip`: strip a leading `./` (added by `zip -r archive .`)
    /// and any trailing slash on directories.
    private static func normalizeZipPath(_ path: String) -> String {
        var p = path
        if p.hasPrefix("./") { p.removeFirst(2) }
        if p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Re-derive sizes via `unzip -v`, which ships with every macOS and handles
    /// ZIP64 correctly — used when ZIPFoundation returns suspicious sentinel values.
    private func readSizesViaFallback() -> [String: (uncompressed: UInt64, compressed: UInt64)] {
        return readSizesViaUnzipV()
    }

    /// Fallback: parse `unzip -v` output. Columns are fixed-width
    /// in macOS's stock `unzip 6.00`; we parse by splitting on whitespace
    /// and taking the entry name as everything after column 8. `unzip` always
    /// ships with macOS — no install prompt, no extra dependency.
    ///
    /// Sample line we're parsing:
    /// ```
    ///  4294967299  Defl:N   1234567  99% 2026-04-22 10:23 a1b2c3d4  some/path.mov
    /// ```
    /// Columns: uncompressed, method, compressed, ratio, date, time, crc, name.
    private func readSizesViaUnzipV() -> [String: (uncompressed: UInt64, compressed: UInt64)] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-v", url.path]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return [:] }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [:] }

        var sizes: [String: (UInt64, UInt64)] = [:]
        // Skip header/footer lines by requiring a valid UInt64 in column 0
        // and a date-shaped token in column 4.
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 8,
                  let uncompressed = UInt64(parts[0]),
                  let compressed   = UInt64(parts[2]),
                  parts[4].contains("-") // date column
            else { continue }
            // Name may contain spaces → rejoin everything from column 7 onward.
            let name = parts[7...].joined(separator: " ")
            sizes[ZipHandler.normalizeZipPath(name)] = (uncompressed, compressed)
        }
        return sizes
    }

    func extract(paths: [String], to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        guard !paths.isEmpty else { return }

        // Decide routing strategy:
        //   • ZIPFoundation per-entry is fastest for small subsets of any
        //     archive — no whole-archive scan, no temp buffer.
        //   • ditto -x -k is the robust fallback for "extract everything"
        //     on archives with AppleDouble, ZIP64, or >50 entries, where
        //     ZIPFoundation either has correctness bugs or gets slow.
        //   • For a small subset (< 1/4) of a problematic archive, we still
        //     prefer per-entry via ZIPFoundation's streaming extractor —
        //     pulling one .mov out of a 50 GB archive shouldn't require
        //     dittoing the whole thing to /tmp first.
        let problematic = isArchiveProblematic()
        let shouldDitto: Bool = {
            if paths.count > 50 { return true }              // user asked for a lot
            if problematic {
                let total = cachedFileCount ?? paths.count
                // Partial extracts of problematic archives still go per-entry
                // if we're pulling less than 1/4 of the archive's files.
                return paths.count >= total / 4
            }
            return false
        }()

        if shouldDitto {
            try extractViaDitto(paths: paths, to: destination)
            return
        }

        let archive = try openArchive(mode: .read)
        let wanted = Set(paths)
        var found: Set<String> = []
        for entry in archive where wanted.contains(entry.path) {
            found.insert(entry.path)
            let target = destination.appendingPathComponent(entry.path)
            try fm.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try archive.extract(entry, to: target)
        }
        if found.count != wanted.count {
            let missing = wanted.subtracting(found).sorted().prefix(3).joined(separator: ", ")
            throw ArchiveError.notFound("Entry not found: \(missing)")
        }
    }

    /// Memoized variant of `isProblematicArchive`. The check opens the
    /// archive and iterates every entry, which is O(n) with a disk-seek
    /// per entry — for a 100 k-entry archive that's measurable. We cache
    /// the result per `ZipHandler` instance, and incidentally cache the
    /// file-count so the ditto threshold doesn't need a second `list()`.
    private func isArchiveProblematic() -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cachedIsProblematic { return cached }

        guard let archive = try? Archive(url: url, accessMode: .read) else {
            cachedIsProblematic = true
            cachedFileCount = 0
            return true
        }
        var fileCount = 0
        var problematic = false
        for entry in archive {
            if entry.type != .directory { fileCount += 1 }
            if !problematic,
               ZipHandler.isSuspiciousSize(entry.uncompressedSize)
                || ZipHandler.isSuspiciousSize(entry.compressedSize) {
                problematic = true
            }
        }
        cachedIsProblematic = problematic
        cachedFileCount = fileCount
        return problematic
    }

    private func extractViaDitto(paths: [String], to destination: URL) throws {
        // We use ditto if we are extracting the ENTIRE archive,
        // otherwise it's terribly inefficient.
        let allFiles = cachedFileCount ?? ((try? list().filter { !$0.isDirectory }.count) ?? 0)
        let isEverything = paths.count >= allFiles || allFiles == 0

        if isEverything {
            try runDitto(to: destination)
        } else {
            let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }
            try runDitto(to: tmp)
            for path in paths {
                let src = tmp.appendingPathComponent(path)
                let dst = destination.appendingPathComponent(path)
                if fm.fileExists(atPath: src.path) {
                    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                    try fm.moveItem(at: src, to: dst)
                }
            }
        }
    }

    private func runDitto(to dest: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", url.path, dest.path]
        
        let pipe = Pipe()
        proc.standardError = pipe
        
        try proc.run()
        proc.waitUntilExit()
        
        guard proc.terminationStatus == 0 else {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let msg = errorString.isEmpty ? "exit code \(proc.terminationStatus)" : errorString
            throw ArchiveError.extractFailed("ditto failed: \(msg)")
        }
    }

    private var fm: FileManager { .default }


    func extractToMemory(path: String) throws -> Data {
        // Use ZIPFoundation directly: iterate entries and find the one whose
        // path matches exactly (ZIPFoundation decoded it; we use the same string,
        // so no codec mismatch is possible). Extract via the streaming closure so
        // we never need the (potentially corrupt) size field — only the compressed
        // payload matters, which ZIPFoundation reads correctly even for ZIP64.
        let archive = try openArchive(mode: .read)
        guard let entry = archive.first(where: { $0.path == path }) else {
            throw ArchiveError.notFound("Entry not found: \(path)")
        }
        var result = Data()
        _ = try archive.extract(entry) { chunk in result.append(chunk) }
        return result
    }

    func delete(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        // Use the system `zip -d` command for true in-place deletion.
        // This modifies the ZIP's central directory directly — no copy needed,
        // so it works even when disk space is nearly full.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.arguments = ["-d", url.path] + paths
        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
            // zip -d returns 12 if nothing was found to delete — that's OK
            if proc.terminationStatus == 12 { return }
            throw ArchiveError.extractFailed(
                "zip -d failed (exit \(proc.terminationStatus)): \(errMsg)")
        }
    }

    private func openArchive(mode: Archive.AccessMode) throws -> Archive {
        do {
            return try Archive(url: url, accessMode: mode)
        } catch {
            throw ArchiveError.readFailed("Could not open ZIP: \(error.localizedDescription)")
        }
    }

}
