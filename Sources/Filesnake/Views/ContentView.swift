import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var document: ArchiveDocument
    @State private var isDragTargeted = false

    var body: some View {
        ThreePaneSplit(
            left: SidebarView().environmentObject(document),
            center: VStack(spacing: 0) {
                if document.archiveURL != nil {
                    FolderBreadcrumbBar().environmentObject(document)
                }
                ArchiveListView().environmentObject(document)
            },
            right: PreviewPane().environmentObject(document)
        )
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

// MARK: - NSSplitView-backed three-pane layout

struct ThreePaneSplit<L: View, C: View, R: View>: NSViewRepresentable {
    let left: L
    let center: C
    let right: R

    static var sidebarMin: CGFloat { 180 }
    static var sidebarMax: CGFloat { 340 }
    static var centerMin: CGFloat  { 340 }
    static var previewMin: CGFloat { 220 }
    static var previewMax: CGFloat { 480 }
    static var initialSidebar: CGFloat { 220 }
    static var initialPreview: CGFloat { 300 }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = context.coordinator
        split.translatesAutoresizingMaskIntoConstraints = false

        let leftHost   = NSHostingView(rootView: left)
        let centerHost = NSHostingView(rootView: center)
        let rightHost  = NSHostingView(rootView: right)

        [leftHost, centerHost, rightHost].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            split.addArrangedSubview($0)
        }

        // When the window resizes: center yields first; sidebar + preview keep their size.
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(240), forSubviewAt: 1)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 2)

        context.coordinator.split = split
        context.coordinator.leftHost = leftHost
        context.coordinator.centerHost = centerHost
        context.coordinator.rightHost = rightHost

        // Initial divider positions (once the split has a real width).
        DispatchQueue.main.async {
            let w = split.bounds.width
            guard w > 0 else { return }
            split.setPosition(Self.initialSidebar, ofDividerAt: 0)
            split.setPosition(w - Self.initialPreview, ofDividerAt: 1)
        }
        return split
    }

    func updateNSView(_ split: NSSplitView, context: Context) {
        context.coordinator.leftHost?.rootView   = left
        context.coordinator.centerHost?.rootView = center
        context.coordinator.rightHost?.rootView  = right
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        weak var split: NSSplitView?
        var leftHost: NSHostingView<L>?
        var centerHost: NSHostingView<C>?
        var rightHost: NSHostingView<R>?

        func splitView(_ splitView: NSSplitView,
                       constrainMinCoordinate proposedMin: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            switch dividerIndex {
            case 0: return ThreePaneSplit.sidebarMin
            case 1:
                let leftEdge = splitView.arrangedSubviews[0].frame.maxX + splitView.dividerThickness
                return leftEdge + ThreePaneSplit.centerMin
            default: return proposedMin
            }
        }

        func splitView(_ splitView: NSSplitView,
                       constrainMaxCoordinate proposedMax: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            switch dividerIndex {
            case 0: return ThreePaneSplit.sidebarMax
            case 1:
                let previewMin = splitView.bounds.width - ThreePaneSplit.previewMax
                let previewMaxConstraint = splitView.bounds.width - ThreePaneSplit.previewMin
                return min(previewMaxConstraint, max(previewMin, proposedMax))
            default: return proposedMax
            }
        }

        // Keep sidebar + preview fixed when the window resizes; center absorbs the delta.
        func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
            let subs = splitView.arrangedSubviews
            guard subs.count == 3 else {
                splitView.adjustSubviews(); return
            }
            let total = splitView.bounds.width
            let dT = splitView.dividerThickness
            let leftW  = max(ThreePaneSplit.sidebarMin,
                             min(ThreePaneSplit.sidebarMax, subs[0].frame.width))
            let rightW = max(ThreePaneSplit.previewMin,
                             min(ThreePaneSplit.previewMax, subs[2].frame.width))
            let centerW = max(ThreePaneSplit.centerMin, total - leftW - rightW - 2 * dT)
            let height = splitView.bounds.height
            subs[0].frame = NSRect(x: 0, y: 0, width: leftW, height: height)
            subs[1].frame = NSRect(x: leftW + dT, y: 0, width: centerW, height: height)
            subs[2].frame = NSRect(x: leftW + centerW + 2 * dT, y: 0, width: rightW, height: height)
        }
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
