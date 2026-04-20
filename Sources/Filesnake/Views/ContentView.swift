import SwiftUI
import AppKit

// MARK: - Root window layout

struct ContentView: View {
    @EnvironmentObject var document: ArchiveDocument
    @State private var isDragTargeted = false

    var body: some View {
        // RawSplitView is a bare NSSplitView NSViewRepresentable.
        // This gives us real NSSplitView cursor rects (resize arrows on dividers)
        // without any SwiftUI HSplitView wrapper intercepting cursor events.
        RawSplitView {
            SidebarView()
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
                }
                ArchiveListView()
            }
            .frame(minWidth: 340, idealWidth: 500)
        } trailing: {
            PreviewPane()
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

// MARK: - Raw NSSplitView wrapper (3-pane, vertical dividers, resize cursors)

private struct RawSplitView<Leading: View, Center: View, Trailing: View>: NSViewRepresentable {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var center: () -> Center
    @ViewBuilder var trailing: () -> Trailing

    func makeNSView(context: Context) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.autoresizingMask = [.width, .height]

        // Host each SwiftUI pane in its own NSHostingView inside an NSView container
        let leadingHost  = host(leading(), minWidth: 180)
        let centerHost   = host(center(),  minWidth: 340)
        let trailingHost = host(trailing(), minWidth: 200)

        split.addArrangedSubview(leadingHost)
        split.addArrangedSubview(centerHost)
        split.addArrangedSubview(trailingHost)

        // Give NSSplitView a chance to lay out before setting initial positions
        DispatchQueue.main.async {
            let total = split.bounds.width
            if total > 0 {
                split.setPosition(220, ofDividerAt: 0)
                split.setPosition(total - 280, ofDividerAt: 1)
            }
        }
        return split
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {}

    private func host<V: View>(_ view: V, minWidth: CGFloat) -> NSView {
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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
                    .buttonStyle(.link)
                    .disabled(document.currentFolderPath.isEmpty)
                ForEach(Array(document.breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(crumb) { document.goToBreadcrumb(index: index) }
                        .buttonStyle(.link)
                        .disabled(index == document.breadcrumbs.count - 1)
                }
                if !document.currentFolderPath.isEmpty {
                    Spacer(minLength: 12)
                    Button { document.goBack() } label: {
                        Label("Up", systemImage: "arrow.uturn.backward")
                    }.labelStyle(.titleAndIcon)
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
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
                Image(systemName: "archivebox").font(.system(size: 32, weight: .light)).foregroundStyle(Color.accentColor)
                Text("Release to Open Archive").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.accentColor)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
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
