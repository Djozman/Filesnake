import SwiftUI
import AppKit

struct SidebarView: View {
    @EnvironmentObject var document: ArchiveDocument
    @State private var selectedFavorite: String? = nil

    /// Standard macOS folders shown in the sidebar
    private static let favoriteLocations: [(name: String, icon: String, directory: FileManager.SearchPathDirectory)] = [
        ("Desktop",   "menubar.dock.rectangle",    .desktopDirectory),
        ("Downloads", "arrow.down.circle.fill",     .downloadsDirectory),
        ("Documents", "doc.fill",                   .documentDirectory),
    ]

    /// Supported archive extensions
    private static let archiveExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "rar", "7z", "bz2", "xz"
    ]

    var body: some View {
        List(selection: $selectedFavorite) {
            // MARK: - Favorites with expandable file lists
            Section("Favorites") {
                ForEach(Self.favoriteLocations, id: \.name) { loc in
                    if let url = FileManager.default.urls(for: loc.directory, in: .userDomainMask).first {
                        FolderDisclosureGroup(
                            name: loc.name,
                            icon: loc.icon,
                            folderURL: url,
                            document: document
                        )
                    }
                }
            }


            if document.archiveURL != nil {
                Section("Selection") {
                    let checkedFiles = document.checkedEntries.filter { !$0.isDirectory }
                    let checkedSize  = checkedFiles.reduce(UInt64(0)) { $0 + $1.uncompressedSize }
                    let dominantType = Self.dominantType(checkedFiles)

                    HStack {
                        Label("Checked", systemImage: "checkmark.circle")
                        Spacer()
                        Text("\(document.checked.count)").foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("Checked Size", systemImage: "scalemass")
                        Spacer()
                        Text(checkedSize > 0 ? Formatters.bytes(checkedSize) : "\u{2014}")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("Mostly", systemImage: "tag")
                        Spacer()
                        Text(dominantType ?? "\u{2014}").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Helpers

    private static func dominantType(_ entries: [ArchiveEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        var freq: [String: Int] = [:]
        for e in entries {
            let ext = (e.name as NSString).pathExtension.lowercased()
            let key = ext.isEmpty ? "(no ext)" : ".\(ext)"
            freq[key, default: 0] += 1
        }
        return freq.max(by: { $0.value < $1.value })?.key
    }
}

// MARK: - Expandable folder with all files listed

private struct FolderDisclosureGroup: View {
    let name: String
    let icon: String
    let folderURL: URL
    let document: ArchiveDocument

    @State private var isExpanded = false
    @State private var items: [FileItem] = []
    @State private var selectedItem: String? = nil
    @State private var archiveCount: Int = 0

    private static let archiveExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "rar", "7z", "bz2", "xz"
    ]

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if items.isEmpty {
                Text("Empty")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            } else {
                ForEach(items) { item in
                    FileItemRow(item: item, document: document, selectedItem: $selectedItem)
                }
            }
        } label: {
            HStack {
                Label(name, systemImage: icon)
                Spacer()
                if archiveCount > 0 {
                    Text("\(archiveCount)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(Color.secondary.opacity(0.18))
                        )
                        .help("\(archiveCount) archive\(archiveCount == 1 ? "" : "s") in \(name)")
                }
            }
            .contextMenu {
                Button("Show in Finder") {
                    NSWorkspace.shared.open(folderURL)
                }
            }
        }
        .onAppear { refreshArchiveCount() }
        .onChange(of: isExpanded) { expanded in
            if expanded {
                scanFolder()
            } else {
                refreshArchiveCount()
            }
        }
    }

    /// Lightweight count (no file metadata) for the badge.
    private func refreshArchiveCount() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            archiveCount = 0
            return
        }
        archiveCount = contents.reduce(0) { acc, url in
            Self.archiveExtensions.contains(url.pathExtension.lowercased()) ? acc + 1 : acc
        }
    }

    private func scanFolder() {
        let fm = FileManager.default
        do {
            let contents = try fm.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
            items = contents.map { url in
                var isDir: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &isDir)
                let size: UInt64
                if let attrs = try? fm.attributesOfItem(atPath: url.path),
                   let s = attrs[.size] as? UInt64 {
                    size = s
                } else {
                    size = 0
                }
                let ext = url.pathExtension.lowercased()
                let isArchive = Self.archiveExtensions.contains(ext)
                return FileItem(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: isDir.boolValue,
                    isArchive: isArchive,
                    size: size
                )
            }
            .sorted { a, b in
                // Directories first, then alphabetical
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            archiveCount = items.reduce(0) { acc, item in
                (!item.isDirectory && item.isArchive) ? acc + 1 : acc
            }
        } catch {
            items = []
            archiveCount = 0
        }
    }
}

// MARK: - File item model

private struct FileItem: Identifiable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isArchive: Bool
    let size: UInt64

    var id: String { url.path }

    var icon: String {
        if isDirectory { return "folder.fill" }
        if isArchive { return "doc.zipper" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "photo"
        case "mp4", "mov", "avi", "mkv": return "film"
        case "mp3", "wav", "aac", "flac": return "music.note"
        case "txt", "md", "rtf": return "doc.text"
        case "swift", "py", "js", "ts", "c", "cpp", "h": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    var iconColor: Color {
        if isDirectory { return .blue }
        if isArchive { return .orange }
        return .secondary
    }
}

// MARK: - Single file item row

private struct FileItemRow: View {
    let item: FileItem
    let document: ArchiveDocument
    @Binding var selectedItem: String?

    var body: some View {
        Button {
            selectedItem = item.id
            if item.isArchive {
                document.sidebarPreviewURL = nil
                document.open(url: item.url)
            } else {
                // Preview in the preview pane instead of opening externally
                document.sidebarPreviewURL = item.url
                document.focused = nil  // Clear archive entry focus
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.icon)
                    .foregroundStyle(item.iconColor)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(item.isArchive ? .primary : .primary)
                    if !item.isDirectory {
                        Text(Formatters.bytes(item.size))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selectedItem == item.id
                          ? Color.accentColor.opacity(0.2)
                          : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            if item.isArchive {
                Button("Open in Filesnake") {
                    document.open(url: item.url)
                }
            }
        }
    }
}
