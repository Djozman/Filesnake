import SwiftUI

struct ContentView: View {
    @EnvironmentObject var document: ArchiveDocument

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } content: {
            VStack(spacing: 0) {
                if document.archiveURL != nil {
                    FolderBreadcrumbBar()
                }
                ArchiveListView()
            }
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

private struct FolderBreadcrumbBar: View {
    @EnvironmentObject var document: ArchiveDocument

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button("Root") {
                    document.goToRoot()
                }
                .buttonStyle(.link)
                .disabled(document.currentFolderPath.isEmpty)

                ForEach(Array(document.breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Button(crumb) {
                        document.goToBreadcrumb(index: index)
                    }
                    .buttonStyle(.link)
                    .disabled(index == document.breadcrumbs.count - 1)
                }

                if !document.currentFolderPath.isEmpty {
                    Spacer(minLength: 12)
                    Button {
                        document.goBack()
                    } label: {
                        Label("Up", systemImage: "arrow.uturn.backward")
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
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
