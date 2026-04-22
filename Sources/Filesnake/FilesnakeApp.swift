import SwiftUI
import UniformTypeIdentifiers
import AppKit

final class AppDelegate: NSObject {
    var document: ArchiveDocument?
    func observeSaveProgress(for document: ArchiveDocument) {}
}

@main
struct FilesnakeApp: App {
    @StateObject private var document = ArchiveDocument()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(document)
                .frame(minWidth: 1060, minHeight: 620)
                .navigationTitle("")
                .onOpenURL { url in
                    document.open(url: url)
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
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
