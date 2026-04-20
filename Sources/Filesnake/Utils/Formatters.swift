import Foundation
import AppKit
import UniformTypeIdentifiers

enum Formatters {
    static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    static func bytes(_ value: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(value))
    }

    static func date(_ value: Date?) -> String {
        value.map { dateFormatter.string(from: $0) } ?? "—"
    }
}

enum FileIcon {
    static func icon(for entry: ArchiveEntry) -> NSImage {
        if entry.isDirectory {
            return NSWorkspace.shared.icon(for: .folder)
        }
        let ext = entry.pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: .data)
    }
}
