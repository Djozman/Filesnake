import SwiftUI

struct ContentView: View {
    @EnvironmentObject var document: ArchiveDocument

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } content: {
            ArchiveListView()
                .navigationSplitViewColumnWidth(min: 360, ideal: 520)
        } detail: {
            PreviewPane()
        }
        .searchable(text: $document.searchText, placement: .toolbar, prompt: "Search files in archive")
        .toolbar { ArchiveToolbar() }
        .alert("Problem", isPresented: Binding(
            get: { document.lastError != nil },
            set: { if !$0 { document.lastError = nil } }
        )) {
            Button("OK") { document.lastError = nil }
        } message: {
            Text(document.lastError ?? "")
        }
        .overlay {
            if document.archiveURL == nil {
                EmptyStateView()
            }
        }
        .overlay(alignment: .bottom) {
            if document.isBusy {
                StatusBar(text: "Working…")
            } else if document.archiveURL != nil {
                StatusBar(text: statusText)
            }
        }
    }

    private var statusText: String {
        let (count, size) = document.stats
        let fmt = document.format?.displayName ?? ""
        return "\(fmt) · \(count) files · \(Formatters.bytes(size))"
    }
}

private struct StatusBar: View {
    let text: String
    var body: some View {
        HStack {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
