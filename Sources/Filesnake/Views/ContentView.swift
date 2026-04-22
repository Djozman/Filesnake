import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var document: ArchiveDocument
    @State private var isDragTargeted = false
    @State private var sidebarVisible = true
    @State private var previewVisible = false

    var body: some View {
        VStack(spacing: 0) {
            InlineTopBar(sidebarVisible: $sidebarVisible, previewVisible: $previewVisible)
            ThreePaneSplit(
                left: SidebarView().environmentObject(document),
                center: VStack(spacing: 0) {
                    if document.archiveURL != nil {
                        FolderBreadcrumbBar().environmentObject(document)
                    }
                    ArchiveListView().environmentObject(document)
                },
                right: PreviewPane().environmentObject(document),
                sidebarVisible: $sidebarVisible,
                previewVisible: $previewVisible
            )
            if document.isBusy {
                StatusBar(text: "Working\u{2026}", busy: true)
            } else if document.archiveURL != nil {
                StatusBar(text: statusText, busy: false)
            }
        }
        .toolbar {
            ArchiveToolbar()
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
        .onChange(of: document.focused) { newFocused in
            if let id = newFocused,
               let entry = document.entries.first(where: { $0.id == id }),
               !entry.isDirectory {
                previewVisible = true
            }
        }
    }

    private var statusText: String {
        let (count, size) = document.stats
        return "\(document.format?.displayName ?? "") \u{00b7} \(count) files \u{00b7} \(Formatters.bytes(size))"
    }
}

// MARK: - NSSplitView with visible divider and reliable cursor/hit-test

private final class InvisibleSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 1 }

    override func drawDivider(in rect: NSRect) {
        NSColor.separatorColor.setFill()
        rect.fill()
    }

    private let hotZone: CGFloat = 5
    private var dividerTrackingAreas: [NSTrackingArea] = []
    private var cursorPushed = false

    private func dividerIndex(at point: NSPoint) -> Int? {
        let dT = dividerThickness
        let subs = arrangedSubviews
        for i in 0..<(subs.count - 1) {
            if subs[i].isHidden { continue }
            let maxX = subs[i].frame.maxX
            let lo = maxX - hotZone
            let hi = maxX + dT + hotZone
            if isVertical {
                if point.x >= lo && point.x <= hi { return i }
            } else {
                if point.y >= lo && point.y <= hi { return i }
            }
        }
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if dividerIndex(at: point) != nil { return self }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        for area in dividerTrackingAreas { removeTrackingArea(area) }
        dividerTrackingAreas.removeAll()
        let subs = arrangedSubviews
        let dT = dividerThickness
        for i in 0..<(subs.count - 1) {
            if subs[i].isHidden { continue }
            let maxX = subs[i].frame.maxX
            let zoneRect = NSRect(x: maxX - hotZone, y: 0, width: dT + hotZone * 2, height: bounds.height)
            let area = NSTrackingArea(rect: zoneRect,
                                      options: [.mouseEnteredAndExited, .activeInActiveApp],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            dividerTrackingAreas.append(area)
        }
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        if !cursorPushed { NSCursor.resizeLeftRight.push(); cursorPushed = true }
    }

    override func mouseExited(with event: NSEvent) {
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if dividerIndex(at: point) != nil { window?.makeFirstResponder(self) }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) { super.mouseDragged(with: event) }
    func mouseDownCanMoveWindow() -> Bool { false }
}

// MARK: - Three-pane split

struct ThreePaneSplit<L: View, C: View, R: View>: NSViewRepresentable {
    let left: L
    let center: C
    let right: R
    @Binding var sidebarVisible: Bool
    @Binding var previewVisible: Bool

    // Layout constants
    private static var sidebarMin:     CGFloat { 140 }
    private static var sidebarMax:     CGFloat { 340 }
    private static var centerMin:      CGFloat { 200 }
    private static var previewMin:     CGFloat { 160 }
    private static var previewMax:     CGFloat { 600 }
    private static var initialSidebar: CGFloat { 220 }
    private static var initialPreview: CGFloat { 300 }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSplitView {
        let split = InvisibleSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = context.coordinator
        split.autoresizingMask = [.width, .height]

        let leftHost   = NSHostingView(rootView: left)
        let centerHost = NSHostingView(rootView: center)
        let rightHost  = NSHostingView(rootView: right)

        for v in [leftHost, centerHost, rightHost] as [NSView] {
            v.autoresizingMask = [.width, .height]
            split.addArrangedSubview(v)
        }

        // Right pane hidden by default; sidebar shown.
        rightHost.isHidden = true
        context.coordinator.sidebarShown = true
        context.coordinator.previewShown = false

        context.coordinator.split      = split
        context.coordinator.leftHost   = leftHost
        context.coordinator.centerHost = centerHost
        context.coordinator.rightHost  = rightHost

        // Defer first layout until the split has real bounds.
        DispatchQueue.main.async {
            guard split.bounds.width > 0 else { return }
            split.setPosition(Self.initialSidebar, ofDividerAt: 0)
        }
        return split
    }

    func updateNSView(_ split: NSSplitView, context: Context) {
        // Always update SwiftUI content.
        context.coordinator.leftHost?.rootView   = left
        context.coordinator.centerHost?.rootView = center
        context.coordinator.rightHost?.rootView  = right

        let c = context.coordinator

        // --- Sidebar ---
        if sidebarVisible != c.sidebarShown {
            c.sidebarShown = sidebarVisible
            let subs = split.arrangedSubviews
            if sidebarVisible {
                subs[0].isHidden = false
                if subs[0].frame.width < Self.sidebarMin {
                    subs[0].frame.size.width = Self.initialSidebar
                }
                split.adjustSubviews()
            } else {
                subs[0].isHidden = true
            }
        }

        // --- Preview ---
        if previewVisible != c.previewShown {
            c.previewShown = previewVisible
            let subs = split.arrangedSubviews
            if previewVisible {
                // Unhide first so NSSplitView counts it in layout.
                subs[2].isHidden = false
                if subs[2].frame.width < Self.previewMin {
                    subs[2].frame.size.width = Self.initialPreview
                }
                split.adjustSubviews()
            } else {
                subs[2].isHidden = true
            }
        }
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        weak var split: NSSplitView?
        var leftHost:   NSHostingView<L>?
        var centerHost: NSHostingView<C>?
        var rightHost:  NSHostingView<R>?

        /// Mirrors the binding values so we only act on actual changes.
        var sidebarShown = true
        var previewShown = false

        // Constants duplicated here for delegate use.
        private let sidebarMin: CGFloat = 140
        private let sidebarMax: CGFloat = 340
        private let centerMin:  CGFloat = 200
        private let previewMin: CGFloat = 160
        private let previewMax: CGFloat = 600

        func splitView(_ splitView: NSSplitView,
                       constrainMinCoordinate proposedMin: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            let subs = splitView.arrangedSubviews
            let dT   = splitView.dividerThickness
            switch dividerIndex {
            case 0: return sidebarMin
            case 1:
                let leftEdge: CGFloat = subs[0].isHidden ? 0 : subs[0].frame.maxX + dT
                return leftEdge + centerMin
            default: return proposedMin
            }
        }

        func splitView(_ splitView: NSSplitView,
                       constrainMaxCoordinate proposedMax: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            switch dividerIndex {
            case 0: return sidebarMax
            case 1: return splitView.bounds.width - previewMin
            default: return proposedMax
            }
        }

        func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
            let subs = splitView.arrangedSubviews
            guard subs.count == 3 else { splitView.adjustSubviews(); return }
            let total  = splitView.bounds.width
            let dT     = splitView.dividerThickness
            let leftHidden  = subs[0].isHidden
            let rightHidden = subs[2].isHidden
            let leftW:  CGFloat = leftHidden  ? 0 : max(sidebarMin, min(sidebarMax, subs[0].frame.width))
            let rightW: CGFloat = rightHidden ? 0 : max(previewMin, min(previewMax, subs[2].frame.width))
            let dividers: CGFloat = (leftHidden ? 0 : 1) + (rightHidden ? 0 : 1)
            let centerW = max(centerMin, total - leftW - rightW - dividers * dT)
            let h = splitView.bounds.height
            var x: CGFloat = 0
            if !leftHidden  { subs[0].frame = NSRect(x: x, y: 0, width: leftW,   height: h); x += leftW + dT }
            subs[1].frame = NSRect(x: x, y: 0, width: centerW, height: h); x += centerW
            print("Layout -> left: (subs[0].frame), center: (subs[1].frame), right: (subs[2].frame)")

            if !rightHidden { x += dT; subs[2].frame = NSRect(x: x, y: 0, width: rightW, height: h) }
        }

        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
            let subs = splitView.arrangedSubviews
            return subview === subs.first || subview === subs.last
        }
    }
}

// MARK: - Inline top bar

struct InlineTopBar: View {
    @Binding var sidebarVisible: Bool
    @Binding var previewVisible: Bool
    var body: some View {
        HStack(spacing: 0) {
            Button { sidebarVisible.toggle() } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
            .padding(.leading, 6)
            Spacer()
            Button { previewVisible.toggle() } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(previewVisible ? "Hide Preview" : "Show Preview")
            .padding(.trailing, 6)
        }
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
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
                if busy { ProgressView().scaleEffect(0.55).frame(width: 14, height: 14) }
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 22)
            .background(.bar)
        }
    }
}

// MARK: - Save progress card

struct SaveProgressCard: View {
    let progress: Double
    let statusText: String

    var title: String {
        if progress >= 1.0 { return "Complete" }
        if statusText.contains("Extracting") { return "Extracting\u{2026}" }
        if statusText.contains("Verifying") { return "Verifying\u{2026}" }
        return "Saving\u{2026}"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusText.contains("Extracting") ? "arrow.up.doc.fill"
                  : (statusText.contains("Verifying") || statusText.contains("No errors")
                     ? "checkmark.seal.fill" : "archivebox.fill"))
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if progress >= 0 {
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .animation(.linear(duration: 0.2), value: progress)
                Text(statusText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(Material.regular)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
    }
}
