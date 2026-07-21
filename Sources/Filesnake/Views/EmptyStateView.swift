import SwiftUI
import AppKit

struct EmptyStateView: View {
    @EnvironmentObject var document: ArchiveDocument
    @State private var recentArchives: [URL] = []

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), FilesnakeTheme.accent.opacity(0.055)],
                startPoint: .top,
                endPoint: .bottomTrailing
            )

            HStack(spacing: 48) {
                welcome
                    .frame(maxWidth: 410, alignment: .leading)

                if !recentArchives.isEmpty {
                    recentPanel
                        .frame(width: 290)
                }
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { refreshRecents() }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            FilesnakeLogo(size: 76)
                .shadow(color: FilesnakeTheme.accent.opacity(0.22), radius: 16, y: 7)
                .padding(.bottom, 28)

            Text("See what’s inside.")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .tracking(-0.7)

            Text("Open, preview, and extract archives without unpacking everything first.")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            HStack(spacing: 10) {
                Button {
                    openArchivePicker()
                } label: {
                    Label("Open Archive", systemImage: "folder.badge.plus")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .tint(FilesnakeTheme.accent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                ShortcutKey(text: "⌘O")
            }
            .padding(.top, 26)

            Label("Or drop an archive anywhere in this window", systemImage: "arrow.down.to.line.compact")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 16)

            HStack(spacing: 8) {
                ForEach(["ZIP", "TAR", "GZIP", "RAR"], id: \.self) { format in
                    Text(format)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(.top, 24)
        }
    }

    private var recentPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent archives")
                    .font(.headline)
                Spacer()
                Image(systemName: "clock")
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            VStack(spacing: 2) {
                ForEach(recentArchives.prefix(6), id: \.path) { url in
                    Button {
                        document.open(url: url)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.zipper")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(FilesnakeTheme.accent)
                                .frame(width: 24, height: 24)
                                .background(FilesnakeTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.primary)
                                Text(url.deletingLastPathComponent().lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.quaternary)
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        }
    }

    private func openArchivePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ArchiveFormat.allowedOpenTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            document.open(url: url)
        }
    }

    private func refreshRecents() {
        recentArchives = NSDocumentController.shared.recentDocumentURLs
            .filter { FileManager.default.fileExists(atPath: $0.path) && ArchiveFormat.detect(url: $0) != nil }
    }
}
