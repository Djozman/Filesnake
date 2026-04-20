import SwiftUI
import UniformTypeIdentifiers

@main
struct FilesnakeApp: App {
    @StateObject private var document = ArchiveDocument()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(document)
                .frame(minWidth: 900, minHeight: 560)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in document.open(url: url) }
                    }
                    return true
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = ArchiveFormat.allowedOpenTypes
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        document.open(url: url)
                    }
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Close Archive") { document.close() }
                    .keyboardShortcut("w", modifiers: [.command])
                    .disabled(document.archiveURL == nil)
            }
        }
    }
}
