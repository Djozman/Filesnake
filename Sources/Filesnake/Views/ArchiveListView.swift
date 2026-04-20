import SwiftUI

struct ArchiveListView: View {
    @EnvironmentObject var document: ArchiveDocument

    var body: some View {
        Table(document.filteredEntries, selection: focusBinding) {
            TableColumn("") { entry in
                Toggle(isOn: checkedBinding(for: entry.id)) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            .width(24)

            TableColumn("Name") { entry in
                HStack(spacing: 6) {
                    Image(nsImage: FileIcon.icon(for: entry))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if entry.isDirectory {
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if entry.isDirectory {
                        document.enterFolder(entry)
                    }
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
        .contextMenu(forSelectionType: ArchiveEntry.ID.self) { ids in
            Button("Check") { ids.forEach { document.checked.insert($0) } }
            Button("Uncheck") { ids.forEach { document.checked.remove($0) } }
            Divider()
            if ids.count == 1,
               let id = ids.first,
               let folder = document.filteredEntries.first(where: { $0.id == id && $0.isDirectory }) {
                Button("Open Folder") { document.enterFolder(folder) }
                Divider()
            }
            Button("Extract Checked…") { document.extractSelection() }
                .disabled(document.checked.isEmpty)
            if document.format?.supportsDeletion == true {
                Divider()
                Button("Delete Checked from Archive", role: .destructive) { document.deleteSelection() }
                    .disabled(document.checked.isEmpty)
            }
        }
    }

    private var focusBinding: Binding<Set<ArchiveEntry.ID>> {
        Binding(
            get: {
                if let f = document.focused { return [f] } else { return [] }
            },
            set: { new in
                document.focused = new.first
            }
        )
    }

    private func checkedBinding(for id: ArchiveEntry.ID) -> Binding<Bool> {
        Binding(
            get: { document.checked.contains(id) },
            set: { on in
                if on { document.checked.insert(id) } else { document.checked.remove(id) }
            }
        )
    }
}
