import SwiftUI

struct ArchiveToolbar: ToolbarContent {
    @EnvironmentObject var document: ArchiveDocument

    var body: some ToolbarContent {
        // Search field — centred via .principal
        ToolbarItem(placement: .principal) {
            ToolbarSearchField(text: $document.searchText)
                .disabled(document.archiveURL == nil)
                .opacity(document.archiveURL == nil ? 0.4 : 1)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                document.checkAllVisible()
            } label: {
                Label("Check All", systemImage: "checkmark.square")
            }
            .disabled(document.archiveURL == nil)
            .help("Check every visible entry")

            Button {
                document.uncheckAll()
            } label: {
                Label("Uncheck All", systemImage: "square")
            }
            .disabled(document.checked.isEmpty)
            .help("Clear all checks")

            Button {
                document.extractSelection()
            } label: {
                Label("Extract Checked", systemImage: "arrow.down.doc")
            }
            .disabled(document.checked.isEmpty)
            .help("Extract checked entries to a folder")

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
                .disabled(document.checked.isEmpty)
                .help("Delete checked entries from the archive")
            } else if document.format?.supportsRepackageAsZIP == true {
                Button {
                    document.deleteSelection()
                } label: {
                    Label("Save Without Checked\u{2026}", systemImage: "doc.badge.arrow.up")
                }
                .disabled(document.checked.isEmpty)
                .help("Save a new ZIP with the checked entries removed. Original archive is not modified.")
            }
        }
    }
}
