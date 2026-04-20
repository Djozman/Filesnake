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
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        let preview = QLPreviewView(frame: .zero, style: .compact) ?? QLPreviewView()
        preview.autostarts = true
        preview.previewItem = url as QLPreviewItem
        context.coordinator.previewView = preview
        return preview
    }

    func updateNSView(_ preview: NSView, context: Context) {
        guard let ql = context.coordinator.previewView else { return }
        if (ql.previewItem as? URL) != url {
            ql.previewItem = url as QLPreviewItem
            context.coordinator.needsFit = true
        }
        if context.coordinator.needsFit {
            context.coordinator.needsFit = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak ql] in
                guard let ql else { return }
                Self.fitContent(ql)
            }
        }
    }

    /// Fit-to-pane only for content whose natural height fits within the pane
    /// (images, PDFs, etc.). For tall text content (README, JSON, source files)
    /// the document height >> pane height, so we just reset to 1:1 and let
    /// the user scroll normally.
    private static func fitContent(_ ql: QLPreviewView) {
        func firstScrollView(_ v: NSView) -> NSScrollView? {
            if let sv = v as? NSScrollView { return sv }
            for sub in v.subviews { if let f = firstScrollView(sub) { return f } }
            return nil
        }
        guard let sv = firstScrollView(ql), let doc = sv.documentView else { return }
        let pane    = ql.bounds.size
        let content = doc.bounds.size
        guard pane.height > 0, pane.width > 0,
              content.height > 0, content.width > 0 else { return }

        sv.allowsMagnification = true

        // If content is a tall scrollable document (text/code/JSON),
        // content height will be many times the pane — just show at 1x.
        if content.height > pane.height * 1.5 {
            sv.setMagnification(1.0, centeredAt: NSPoint(x: content.width / 2, y: content.height))
            return
        }

        // For images/PDFs that fit or are close to fitting, scale down to fill pane.
        let scale = min(1.0, min(pane.height / content.height, pane.width / content.width))
        sv.setMagnification(scale, centeredAt: NSPoint(x: content.width / 2, y: content.height))
    }

    final class Coordinator {
        weak var previewView: QLPreviewView?
        var needsFit = true
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
