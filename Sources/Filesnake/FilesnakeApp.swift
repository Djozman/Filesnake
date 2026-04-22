import SwiftUI
import UniformTypeIdentifiers
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var hudWindow: NSPanel?
    var document: ArchiveDocument? // Keep for legacy if needed, but hud is better
    
    func showHUD(for document: ArchiveDocument) {
        if hudWindow == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.isMovableByWindowBackground = true
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            
            let hostingView = NSHostingView(rootView: HUDWrapper(document: document))
            panel.contentView = hostingView
            panel.center()
            panel.orderFrontRegardless()
            self.hudWindow = panel
        }
    }
    
    func closeHUD() {
        hudWindow?.close()
        hudWindow = nil
    }
    
    func observeSaveProgress(for document: ArchiveDocument) {
        showHUD(for: document)
    }
}

struct HUDWrapper: View {
    @ObservedObject var document: ArchiveDocument
    var body: some View {
        if let progress = document.saveProgress {
            SaveProgressCard(progress: progress, statusText: document.saveStatusText)
                .frame(width: 320)
        } else if document.isBusy {
             // If we have no progress but we are busy, show 0%
             SaveProgressCard(progress: 0, statusText: document.saveStatusText)
                .frame(width: 320)
        }
    }
}

@main
struct FilesnakeApp: App {
    @StateObject private var document = ArchiveDocument()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
                        let isBackground = comps.queryItems?.first(where: { $0.name == "background" })?.value == "1"
                        
                        if isBackground {
                            NSApp.setActivationPolicy(.accessory)
                            NSApp.hide(nil)
                            // Close main windows to stay "background"
                            for window in NSApp.windows where !(window is NSPanel) {
                                window.alphaValue = 0
                                window.orderOut(nil)
                                window.close()
                            }
                        }
                        
                        if comps.host == "extract" {
                            let dest = comps.queryItems?.first(where: { $0.name == "dest" })?.value ?? "here"
                            let trash = comps.queryItems?.first(where: { $0.name == "trash" })?.value == "1"
                            ArchiveDocument.backgroundExtract(urls: urls, dest: dest, trash: trash, appDelegate: appDelegate)
                        } else if comps.host == "test" {
                            ArchiveDocument.testValidity(urls: urls, appDelegate: appDelegate)
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
