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
                        QuickLookView(url: url)
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

private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as QLPreviewItem
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        if (nsView.previewItem as? URL) != url {
            nsView.previewItem = url as QLPreviewItem
        }
    }
}

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

private struct InfoFooter: View {
    let entry: ArchiveEntry
    var body: some View {
        HStack(spacing: 12) {
            Text(entry.name).bold().lineLimit(1)
            Text("·").foregroundStyle(.secondary)
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
