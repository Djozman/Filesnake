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
        if (preview.previewItem as? URL) != url {
            preview.previewItem = url as QLPreviewItem
            context.coordinator.pendingFit = true
        }
        preview.frame = container.bounds
        if context.coordinator.pendingFit {
            context.coordinator.pendingFit = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak preview, weak container] in
                guard let preview, let container else { return }
                Self.fitContent(preview, in: container)
            }
        }
    }

    /// Walk the QLPreviewView subview tree, find the first NSScrollView,
    /// and set its magnification so the document height fits the pane.
    /// Falls back gracefully if the internal structure isn't found.
    private static func fitContent(_ preview: QLPreviewView, in container: NSView) {
        let paneSize = container.bounds.size
        guard paneSize.height > 0, paneSize.width > 0 else { return }

        func findScrollView(_ v: NSView) -> NSScrollView? {
            if let sv = v as? NSScrollView { return sv }
            for sub in v.subviews {
                if let found = findScrollView(sub) { return found }
            }
            return nil
        }

        guard let scrollView = findScrollView(preview),
              let docView = scrollView.documentView else { return }

        let docSize = docView.bounds.size
        guard docSize.height > 0, docSize.width > 0 else { return }

        // Compute scale to fit both dimensions, cap at 1.0 to avoid upscaling
        let scaleH = paneSize.height / docSize.height
        let scaleW = paneSize.width  / docSize.width
        let scale  = min(1.0, min(scaleH, scaleW))

        scrollView.allowsMagnification = true
        scrollView.setMagnification(scale, centeredAt: .zero)
    }

    final class Coordinator {
        weak var previewView: QLPreviewView?
        var pendingFit = true
    }
}

// MARK: - Info card

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
