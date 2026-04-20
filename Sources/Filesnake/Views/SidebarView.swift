import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var document: ArchiveDocument

    var body: some View {
        List {
            Section("Archive") {
                if let url = document.archiveURL {
                    Label(url.lastPathComponent, systemImage: "shippingbox.fill")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let fmt = document.format {
                        Label(fmt.displayName, systemImage: "doc.zipper")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label("No archive open", systemImage: "shippingbox")
                        .foregroundStyle(.secondary)
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

                Section("Archive") {
                    let (count, size) = document.stats
                    HStack {
                        Label("Files", systemImage: "doc.on.doc")
                        Spacer()
                        Text("\(count)").foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("Total Size", systemImage: "internaldrive")
                        Spacer()
                        Text(Formatters.bytes(size)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

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
