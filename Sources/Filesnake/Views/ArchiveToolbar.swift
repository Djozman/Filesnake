import SwiftUI
import AppKit

struct ArchiveToolbar: ToolbarContent {
    @EnvironmentObject var document: ArchiveDocument

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                openArchivePicker()
            } label: {
                Label("Open Archive", systemImage: "folder")
            }
            .help("Open an archive (⌘O)")
        }

        ToolbarItem(placement: .principal) {
            ToolbarSearchField(text: $document.searchText)
                .disabled(document.archiveURL == nil)
                .opacity(document.archiveURL == nil ? 0.45 : 1)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button {
                    document.checkAllVisible()
                } label: {
                    Label("Check Visible", systemImage: "checkmark.square")
                }

                Button {
                    document.uncheckAll()
                } label: {
                    Label("Clear Checks", systemImage: "square")
                }
                .disabled(document.checked.isEmpty)

                if document.format?.supportsDeletion == true {
                    Divider()
                    Button(role: .destructive) {
                        document.deleteSelection()
                    } label: {
                        Label("Delete Checked", systemImage: "trash")
                    }
                    .disabled(document.checked.isEmpty)
                }
            } label: {
                Label(
                    document.checked.isEmpty ? "Select" : "\(document.checked.count) Checked",
                    systemImage: document.checked.isEmpty ? "checkmark.circle" : "checkmark.circle.fill"
                )
            }
            .disabled(document.archiveURL == nil)
            .help("Selection actions")

            Menu {
                Button {
                    document.extractSelection()
                } label: {
                    Label("Extract Checked…", systemImage: "checkmark.square")
                }
                .disabled(document.checked.isEmpty)

                Button {
                    document.extractAll()
                } label: {
                    Label("Extract Everything…", systemImage: "archivebox")
                }
            } label: {
                Label("Extract", systemImage: "arrow.down.to.line.compact")
            }
            .menuStyle(.borderlessButton)
            .disabled(document.archiveURL == nil || document.isBusy)
            .help("Extract files from this archive")
        }
    }

    private func openArchivePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ArchiveFormat.allowedOpenTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            document.open(url: url)
        }
    }
}
