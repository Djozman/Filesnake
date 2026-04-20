import SwiftUI

struct ArchiveListView: View {
    @EnvironmentObject var document: ArchiveDocument

    var body: some View {
        Table(document.filteredEntries, selection: $document.selection) {
            TableColumn("Name") { entry in
                HStack(spacing: 6) {
                    Image(nsImage: FileIcon.icon(for: entry))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(entry.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            TableColumn("Size") { entry in
                Text(entry.isDirectory ? "—" : Formatters.bytes(entry.uncompressedSize))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 90, max: 140)

            TableColumn("Compressed") { entry in
                Text(entry.isDirectory ? "—" : Formatters.bytes(entry.compressedSize))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 100, max: 140)

            TableColumn("Modified") { entry in
                Text(Formatters.date(entry.modified))
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 140, max: 200)
        }
        .contextMenu(forSelectionType: ArchiveEntry.ID.self) { _ in
            Button("Extract Selected…") { document.extractSelection() }
                .disabled(document.selection.isEmpty)
            if document.format?.supportsDeletion == true {
                Divider()
                Button("Delete from Archive", role: .destructive) { document.deleteSelection() }
                    .disabled(document.selection.isEmpty)
            }
        }
    }
}
