import SwiftUI
import AppKit
import Quartz

struct PreviewPane: View {
    @EnvironmentObject var document: ArchiveDocument

    var body: some View {
        Group {
            if let entry = document.currentEntry {
                if entry.isDirectory {
                    InfoCard(entry: entry)
                } else if let url = document.materializeForPreview(entry) {
                    VStack(spacing: 0) {
                        FitQLPreviewView(url: url)
                        Divider()
                        InfoFooter(entry: entry)
                    }
                } else {
                    InfoCard(entry: entry)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "eye")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(document.archiveURL == nil ? "Open an archive to begin" : "Select a file to preview")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
    }
}

// MARK: - Fit-to-pane QLPreviewView

/// Wraps QLPreviewView and, after each layout pass, scales it so the
/// content fits entirely within the visible pane — no vertical scrolling needed.
private struct FitQLPreviewView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true

        let preview = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        preview.autostarts = true
        preview.autoresizingMask = [.width, .height]
        preview.previewItem = url as QLPreviewItem
        container.addSubview(preview)
        context.coordinator.previewView = preview

        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let preview = context.coordinator.previewView else { return }
        // Update URL if changed
        if (preview.previewItem as? URL) != url {
            preview.previewItem = url as QLPreviewItem
            context.coordinator.pendingFit = true
        }
        preview.frame = container.bounds
        // Schedule fit after QuickLook has rendered
        if context.coordinator.pendingFit {
            context.coordinator.pendingFit = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak preview, weak container] in
                guard let preview, let container else { return }
                Self.fitContent(preview, in: container)
            }
        }
    }

    /// Scale the QLPreviewView so its content fills the container height.
    private static func fitContent(_ preview: QLPreviewView, in container: NSView) {
        // QLPreviewView exposes `scaleFactor` for setting zoom level.
        // We walk its subview tree to find the internal scroll view and
        // read its documentView size, then derive the needed scale.
        func findScrollView(_ v: NSView) -> NSScrollView? {
            if let sv = v as? NSScrollView { return sv }
            for sub in v.subviews {
                if let found = findScrollView(sub) { return found }
            }
            return nil
        }

        let paneHeight = container.bounds.height
        guard paneHeight > 0 else { return }

        if let scrollView = findScrollView(preview),
           let docView = scrollView.documentView {
            let docHeight = docView.bounds.height
            guard docHeight > 0 else { return }
            // Scale so the full document height fits in the pane
            let scale = min(1.0, paneHeight / docHeight)
            preview.scaleFactor = scale
        } else {
            // Fallback: just set scale to 1.0 (no oversized rendering)
            preview.scaleFactor = 1.0
        }
    }

    final class Coordinator {
        weak var previewView: QLPreviewView?
        var pendingFit = true
    }
}

// MARK: - Info card (directories / no preview)

private struct InfoCard: View {
    let entry: ArchiveEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.name).font(.title3).bold()
            Text(entry.path).font(.callout).foregroundStyle(.secondary)
            Divider()
            row("Type", entry.isDirectory ? "Folder" : "File")
            row("Uncompressed", Formatters.bytes(entry.uncompressedSize))
            row("Compressed", Formatters.bytes(entry.compressedSize))
            row("Modified", Formatters.date(entry.modified))
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}

// MARK: - Info footer

private struct InfoFooter: View {
    let entry: ArchiveEntry
    var body: some View {
        HStack(spacing: 12) {
            Text(entry.name).bold().lineLimit(1)
            Text("\u{00b7}").foregroundStyle(.secondary)
            Text(Formatters.bytes(entry.uncompressedSize)).foregroundStyle(.secondary)
            Spacer()
            Text(Formatters.date(entry.modified)).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
