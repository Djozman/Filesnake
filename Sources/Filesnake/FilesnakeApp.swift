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
                .frame(minWidth: 480, minHeight: 320)
                .navigationTitle("")
                .onOpenURL { url in
                    if url.scheme == "filesnake" {
                        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
                        let filePaths = comps.queryItems?.filter { $0.name == "file" }.compactMap { $0.value } ?? []
                        let urls = filePaths.map { URL(fileURLWithPath: $0) }
                        
                        if comps.host == "extract" {
                            let dest = comps.queryItems?.first(where: { $0.name == "dest" })?.value ?? "here"
                            let trash = comps.queryItems?.first(where: { $0.name == "trash" })?.value == "1"
                            ArchiveDocument.backgroundExtract(urls: urls, dest: dest, trash: trash, appDelegate: nil)
                        } else if comps.host == "test" {
                            ArchiveDocument.testValidity(urls: urls, appDelegate: nil)
                        }
                    } else {
                        document.open(url: url)
                    }
                }
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
