import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var document: ArchiveDocument
    @State private var isDragTargeted = false

    var body: some View {
        FilesnakeSplitHost {
            SidebarView()
                .environmentObject(document)
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
        } center: {
            VStack(spacing: 0) {
                if document.archiveURL != nil {
                    SearchBarView(text: $document.searchText)
                        .frame(height: 28)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.bar)
                        .overlay(alignment: .bottom) { Divider() }
                    FolderBreadcrumbBar()
                        .environmentObject(document)
                }
                ArchiveListView()
                    .environmentObject(document)
            }
            .frame(minWidth: 340, idealWidth: 500)
        } trailing: {
            PreviewPane()
                .environmentObject(document)
                .frame(minWidth: 200, idealWidth: 280)
        }
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
            if document.archiveURL == nil && !isDragTargeted { EmptyStateView() }
        }
        .overlay {
            if isDragTargeted { DropHighlightOverlay() }
        }
        .overlay(alignment: .bottom) {
            if document.isBusy {
                StatusBar(text: "Working\u{2026}")
            } else if document.archiveURL != nil {
                StatusBar(text: statusText)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, ArchiveFormat.detect(url: url) != nil else { return }
                Task { @MainActor in document.open(url: url) }
            }
            return true
        }
    }

    private var statusText: String {
        let (count, size) = document.stats
        return "\(document.format?.displayName ?? "") \u{00b7} \(count) files \u{00b7} \(Formatters.bytes(size))"
    }
}

// MARK: - NSSplitView subclass with permanent resize cursor

final class FilesnakeSplitView: NSSplitView {
    override func resetCursorRects() {
        super.resetCursorRects()
        for i in 0 ..< arrangedSubviews.count - 1 {
            // rect(ofDivider:) is the correct NSSplitView API
            addCursorRect(rect(ofDivider: i), cursor: .resizeLeftRight)
        }
    }
}

// MARK: - NSViewRepresentable host

private struct FilesnakeSplitHost<L: View, C: View, T: View>: NSViewRepresentable {
    @ViewBuilder var leading: () -> L
    @ViewBuilder var center: () -> C
    @ViewBuilder var trailing: () -> T

    func makeNSView(context: Context) -> FilesnakeSplitView {
        let split = FilesnakeSplitView()
        split.isVertical = true
        split.dividerStyle = .thin

        split.addArrangedSubview(makePane(leading()))
        split.addArrangedSubview(makePane(center()))
        split.addArrangedSubview(makePane(trailing()))

        DispatchQueue.main.async {
            let w = split.bounds.width
            guard w > 0 else { return }
            split.setPosition(220,     ofDividerAt: 0)
            split.setPosition(w - 280, ofDividerAt: 1)
        }
        return split
    }

    func updateNSView(_ splitView: FilesnakeSplitView, context: Context) {
        splitView.window?.invalidateCursorRects(for: splitView)
    }

    private func makePane<V: View>(_ view: V) -> NSView {
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }
}

// MARK: - Breadcrumb bar

struct FolderBreadcrumbBar: View {
    @EnvironmentObject var document: ArchiveDocument
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button("Root") { document.goToRoot() }
                    .buttonStyle(.link).disabled(document.currentFolderPath.isEmpty)
                ForEach(Array(document.breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(crumb) { document.goToBreadcrumb(index: index) }
                        .buttonStyle(.link).disabled(index == document.breadcrumbs.count - 1)
                }
                if !document.currentFolderPath.isEmpty {
                    Spacer(minLength: 12)
                    Button { document.goBack() } label: {
                        Label("Up", systemImage: "arrow.uturn.backward")
                    }.labelStyle(.titleAndIcon)
                }
            }
            .font(.callout).padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(.bar).overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - Drop highlight

struct DropHighlightOverlay: View {
    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.08)
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor, lineWidth: 3).padding(4)
            VStack(spacing: 8) {
                Image(systemName: "archivebox")
                    .font(.system(size: 32, weight: .light)).foregroundStyle(Color.accentColor)
                Text("Release to Open Archive")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.accentColor)
            }
        }
        .ignoresSafeArea().allowsHitTesting(false)
    }
}

// MARK: - Status bar

struct StatusBar: View {
    let text: String
    var body: some View {
        HStack {
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6).background(.bar)
    }
}
