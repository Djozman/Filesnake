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
                Section("Summary") {
                    let (count, size) = document.stats
                    HStack {
                        Label("Files", systemImage: "doc.on.doc")
                        Spacer()
                        Text("\(count)").foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("Size", systemImage: "internaldrive")
                        Spacer()
                        Text(Formatters.bytes(size)).foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("Checked", systemImage: "checkmark.circle")
                        Spacer()
                        Text("\(document.checked.count)").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}
