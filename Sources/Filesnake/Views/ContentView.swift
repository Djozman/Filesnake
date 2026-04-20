import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var document: ArchiveDocument
    @State private var isDragTargeted = false
    @State private var sidebarVisible = true

    var body: some View {
        VStack(spacing: 0) {
            ThreePaneSplit(
                left: SidebarView().environmentObject(document),
                center: VStack(spacing: 0) {
                    if document.archiveURL != nil {
                        FolderBreadcrumbBar().environmentObject(document)
                    }
                    ArchiveListView().environmentObject(document)
                },
                right: PreviewPane().environmentObject(document),
                sidebarVisible: $sidebarVisible
            )
            if document.isBusy {
                StatusBar(text: "Working\u{2026}", busy: true)
            } else if document.archiveURL != nil {
                StatusBar(text: statusText, busy: false)
            }
        }
        .toolbar {
            ArchiveToolbar(sidebarVisible: $sidebarVisible)
        }
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

// MARK: - NSSplitView three-pane layout

struct ThreePaneSplit<L: View, C: View, R: View>: NSViewRepresentable {
    let left: L
    let center: C
    let right: R
    @Binding var sidebarVisible: Bool

    static var sidebarMin:     CGFloat { 180 }
    static var sidebarMax:     CGFloat { 340 }
    static var centerMin:      CGFloat { 340 }
    static var previewMin:     CGFloat { 220 }
    static var previewMax:     CGFloat { 600 }
    static var initialSidebar: CGFloat { 220 }
    static var initialPreview: CGFloat { 300 }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = context.coordinator
        split.autoresizingMask = [.width, .height]

        let leftHost   = NSHostingView(rootView: left)
        let centerHost = NSHostingView(rootView: center)
        let rightHost  = NSHostingView(rootView: right)

        [leftHost, centerHost, rightHost].forEach {
            $0.autoresizingMask = [.width, .height]
            split.addArrangedSubview($0)
        }

        context.coordinator.split      = split
        context.coordinator.leftHost   = leftHost
        context.coordinator.centerHost = centerHost
        context.coordinator.rightHost  = rightHost

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

        let leftView    = split.arrangedSubviews[0]
        let isCollapsed = split.isSubviewCollapsed(leftView)
        if sidebarVisible && isCollapsed {
            split.setPosition(Self.initialSidebar, ofDividerAt: 0)
        } else if !sidebarVisible && !isCollapsed {
            split.setPosition(0, ofDividerAt: 0)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        weak var split: NSSplitView?
        var leftHost:   NSHostingView<L>?
        var centerHost: NSHostingView<C>?
        var rightHost:  NSHostingView<R>?

        // MARK: Constraints — NSSplitView calls these during drag; no manual frame overrides needed.

        func splitView(_ splitView: NSSplitView,
                       constrainMinCoordinate proposedMin: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            let subs = splitView.arrangedSubviews
            let dT   = splitView.dividerThickness
            switch dividerIndex {
            case 0:
                return Self.sidebarMin
            case 1:
                // Left edge of divider 1 must leave enough room for the center
                let leftEdge = splitView.isSubviewCollapsed(subs[0]) ? 0 : subs[0].frame.maxX + dT
                return leftEdge + Self.centerMin
            default:
                return proposedMin
            }
        }

        func splitView(_ splitView: NSSplitView,
                       constrainMaxCoordinate proposedMax: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            switch dividerIndex {
            case 0:
                return Self.sidebarMax
            case 1:
                // Right edge of divider 1 must leave enough room for the preview
                return splitView.bounds.width - Self.previewMin
            default:
                return proposedMax
            }
        }

        // MARK: Window resize — keep panels in bounds

        func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
            let subs          = splitView.arrangedSubviews
            guard subs.count == 3 else { splitView.adjustSubviews(); return }
            let total         = splitView.bounds.width
            let dT            = splitView.dividerThickness
            let leftCollapsed = splitView.isSubviewCollapsed(subs[0])
            let leftW         = leftCollapsed ? 0 : max(Self.sidebarMin, min(Self.sidebarMax, subs[0].frame.width))
            let rightW        = max(Self.previewMin, min(Self.previewMax, subs[2].frame.width))
            let dividers      = leftCollapsed ? dT : 2 * dT
            let centerW       = max(Self.centerMin, total - leftW - rightW - dividers)
            let leftOffset    = leftCollapsed ? 0 : leftW + dT
            let h             = splitView.bounds.height
            if !leftCollapsed {
                subs[0].frame = NSRect(x: 0, y: 0, width: leftW, height: h)
            }
            subs[1].frame = NSRect(x: leftOffset,             y: 0, width: centerW, height: h)
            subs[2].frame = NSRect(x: leftOffset + centerW + dT, y: 0, width: rightW,  height: h)
        }

        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
            return subview === splitView.arrangedSubviews.first
        }

        private static var sidebarMin: CGFloat { 180 }
        private static var sidebarMax: CGFloat { 340 }
        private static var centerMin:  CGFloat { 340 }
        private static var previewMin: CGFloat { 220 }
        private static var previewMax: CGFloat { 600 }
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
    let busy: Bool
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if busy {
                    ProgressView().scaleEffect(0.55).frame(width: 14, height: 14)
                }
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 22)
            .background(.bar)
        }
    }
}
