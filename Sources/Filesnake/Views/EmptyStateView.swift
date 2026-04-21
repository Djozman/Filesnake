import SwiftUI

struct EmptyStateView: View {
    @EnvironmentObject var document: ArchiveDocument

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop an archive here")
                .font(.title2)
            Text("Supports .zip, .tar, .tar.gz, .gz, .rar")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open Archive\u{2026}") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = ArchiveFormat.allowedOpenTypes
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                if panel.runModal() == .OK, let url = panel.url {
                    document.open(url: url)
                }
            }
            .keyboardShortcut(.defaultAction)
            .padding(.top, 8)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
