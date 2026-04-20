import SwiftUI

struct ArchiveToolbar: ToolbarContent {
    @EnvironmentObject var document: ArchiveDocument

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                document.extractSelection()
            } label: {
                Label("Extract Selected", systemImage: "arrow.down.doc")
            }
            .disabled(document.selection.isEmpty)
            .help("Extract selected entries to a folder")

            Button {
                document.extractAll()
            } label: {
                Label("Extract All", systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(document.archiveURL == nil)
            .help("Extract every entry")

            if document.format?.supportsDeletion == true {
                Button(role: .destructive) {
                    document.deleteSelection()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(document.selection.isEmpty)
                .help("Delete selected entries from the archive")
            }
        }
    }
}
