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
                .navigationTitle("")
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open\u{2026}") {
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
