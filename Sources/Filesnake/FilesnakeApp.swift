import SwiftUI
import UniformTypeIdentifiers
import AppKit

@main
struct FilesnakeApp: App {
    @StateObject private var document = ArchiveDocument()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(document)
                .frame(minWidth: 900, minHeight: 560)
                .navigationTitle("")
                .onOpenURL { url in
                    document.open(url: url)
                }
                .onAppear {
                    appDelegate.document = document
                    if let pending = appDelegate.pendingURL {
                        appDelegate.pendingURL = nil
                        document.open(url: pending)
                    }
                    // Close any duplicate windows SwiftUI may have created
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        Self.closeExtraWindows()
                    }
                }
                .handlesExternalEvents(preferring: Set(["*"]), allowing: Set(["*"]))
        }
        .handlesExternalEvents(matching: Set(["*"]))
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

    /// Close any duplicate windows, keeping only the first visible one.
    static func closeExtraWindows() {
        let appWindows = NSApp.windows.filter {
            $0.isVisible && $0.canBecomeMain
        }
        guard appWindows.count > 1 else { return }
        for window in appWindows.dropFirst() {
            window.close()
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    var document: ArchiveDocument?
    var pendingURL: URL?
    private var isPrimary = true

    private static let openNote = Notification.Name("com.filesnake.openFile")

    func applicationWillFinishLaunching(_ notification: Notification) {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "com.filesnake.app"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID }

        if !others.isEmpty {
            isPrimary = false
            NSApp.setActivationPolicy(.accessory)
            others.first?.activate()
            return
        }

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(receivedOpenFile(_:)),
            name: Self.openNote, object: nil
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isPrimary else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if !isPrimary {
            DistributedNotificationCenter.default().postNotificationName(
                Self.openNote, object: url.path,
                userInfo: nil, deliverImmediately: true
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            return
        }
        if let document {
            Task { @MainActor in document.open(url: url) }
        } else {
            pendingURL = url
        }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func receivedOpenFile(_ note: Notification) {
        guard let path = note.object as? String else { return }
        let url = URL(fileURLWithPath: path)
        Task { @MainActor in
            self.document?.open(url: url)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { isPrimary }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        if flag {
            // Already have a visible window — just bring it to front
            NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
            return false
        } else {
            // No visible windows — try to unhide an existing one, or let SwiftUI create one
            if let window = NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
                return false
            }
            return true
        }
    }
}
