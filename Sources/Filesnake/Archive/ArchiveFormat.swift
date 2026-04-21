import Foundation
import UniformTypeIdentifiers

enum ArchiveFormat: String, CaseIterable {
    case zip
    case tar
    case tarGz
    case gz
    case rar

    static func detect(url: URL) -> ArchiveFormat? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") { return .zip }
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tarGz }
        if name.hasSuffix(".tar") { return .tar }
        if name.hasSuffix(".gz") { return .gz }
        if name.hasSuffix(".rar") { return .rar }
        return nil
    }

    static var allowedOpenTypes: [UTType] {
        var types: [UTType] = [.zip, .gzip]
        if let tar = UTType("public.tar-archive") { types.append(tar) }
        if let tgz = UTType("org.gnu.gnu-tar-archive") { types.append(tgz) }
        if let rar = UTType("com.rarlab.rar-archive") { types.append(rar) }
        return types
    }

    var displayName: String {
        switch self {
        case .zip:   return "ZIP"
        case .tar:   return "TAR"
        case .tarGz: return "TAR.GZ"
        case .gz:    return "GZIP"
        case .rar:   return "RAR"
        }
    }

    var supportsDeletion: Bool { self == .zip }
    var supportsRandomExtract: Bool { self == .zip || self == .tar || self == .tarGz }

    /// Read-only formats we can "edit" by extracting survivors and repackaging as a new ZIP.
    var supportsRepackageAsZIP: Bool { self == .rar }

    /// Whether the UI should show a remove/delete button — either in-place or via repackage.
    var canRemoveEntries: Bool { supportsDeletion || supportsRepackageAsZIP }
}
