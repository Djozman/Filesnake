import SwiftUI
import UniformTypeIdentifiers
import AppKit
import Combine

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
                    if url.scheme == "filesnake" {
                        appDelegate.handleActionURL(url)
                    } else {
                        document.open(url: url)
                    }
                }
                .onAppear {
                    appDelegate.takeoverDefaultApp()
                    
                    if appDelegate.isBackgroundAction {
                        for window in NSApp.windows where !(window is NSPanel) {
                            window.alphaValue = 0
                            window.close()
                        }
                        NSApp.hide(nil)
                    }
                    
                    appDelegate.document = document
                    if let pending = appDelegate.pendingURL {
                        appDelegate.pendingURL = nil
                        if pending.scheme == "filesnake" {
                            appDelegate.handleActionURL(pending)
                        } else {
                            document.open(url: pending)
                        }
                    }
                    // Close any duplicate windows SwiftUI may have created
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        if appDelegate.isBackgroundAction {
                            for window in NSApp.windows where !(window is NSPanel) {
                                window.alphaValue = 0
                                window.close()
                            }
                            NSApp.hide(nil)
                        } else {
                            Self.closeExtraWindows()
                        }
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

                Button("Create Archive…") {
                    Self.createArchiveFlow(document: document)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Close Archive") { document.close() }
                    .keyboardShortcut("w", modifiers: [.command])
                    .disabled(document.archiveURL == nil)

                Divider()

                // MARK: Extract presets
                Menu("Extract Checked To…") {
                    Button("Desktop") {
                        extractCheckedToPreset(.desktopDirectory)
                    }
                    Button("Downloads") {
                        extractCheckedToPreset(.downloadsDirectory)
                    }
                    Button("Documents") {
                        extractCheckedToPreset(.documentDirectory)
                    }
                    Divider()
                    Button("Same Folder as Archive") {
                        guard let archiveURL = document.archiveURL else { return }
                        let dest = archiveURL.deletingLastPathComponent()
                        document.extractCheckedTo(dest)
                    }
                    .disabled(document.archiveURL == nil)
                }
                .disabled(document.checked.isEmpty)
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

    /// Extract checked entries to a preset folder (Desktop, Downloads, etc.)
    private func extractCheckedToPreset(_ directory: FileManager.SearchPathDirectory) {
        guard let dest = FileManager.default.urls(for: directory, in: .userDomainMask).first else { return }
        document.extractCheckedTo(dest)
    }

    static func createArchiveFlow(document: ArchiveDocument, predefinedSources: [URL]? = nil) {
        // Step 1: Pick files/folders to archive
        let sources: [URL]
        if let predefined = predefinedSources, !predefined.isEmpty {
            sources = predefined
        } else {
            let openPanel = NSOpenPanel()
            openPanel.allowsMultipleSelection = true
            openPanel.canChooseFiles = true
            openPanel.canChooseDirectories = true
            openPanel.prompt = "Add to Archive"
            openPanel.message = "Select files and folders to compress"
            guard openPanel.runModal() == .OK, !openPanel.urls.isEmpty else { return }
            sources = openPanel.urls
        }

        // Step 2: Choose where to save the ZIP
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.zip]
        savePanel.nameFieldStringValue = "Archive.zip"
        savePanel.prompt = "Create"
        savePanel.message = "Save ZIP archive"
        guard savePanel.runModal() == .OK, let destination = savePanel.url else { return }

        // Step 3: Create the ZIP
        do {
            try ZipCreator.createZip(at: destination, from: sources)
            // Open the newly created archive
            document.open(url: destination)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to create archive"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
        }
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var document: ArchiveDocument? {
        didSet { if let doc = document { observeSaveProgress(for: doc) } }
    }
    var pendingURL: URL?
    var isBackgroundAction = false
    private var isPrimary = true
    private var windowCloseDelegates: [ObjectIdentifier: WindowCloseDelegate] = [:]
    
    private var savePanel: NSPanel?
    private var savePanelHost: NSHostingView<SaveProgressCard>?
    private var saveProgressCancellable: AnyCancellable?
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

        // Drain any handoff files a prior secondary instance left behind
        // because it lost the race with our launch. This is the backup
        // channel for the DistributedNotificationCenter — if the secondary
        // posted before we registered the observer, the notification was
        // lost, but the file stays on disk until we get here.
        drainHandoffQueue()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isPrimary else { return }
        // Secondary instance: we've posted to DistributedNotificationCenter
        // already in `application(_:open:)`, but that can lose the message
        // if the primary is still launching. Wait a bit longer before
        // terminating so the primary has time to ack — and if it doesn't,
        // the file we dropped into the handoff queue will be picked up
        // whenever the primary next launches.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if !isPrimary {
            // Primary channel: post a DistributedNotification. If the primary
            // already registered its observer this gets there immediately.
            DistributedNotificationCenter.default().postNotificationName(
                Self.openNote, object: url.absoluteString,
                userInfo: nil, deliverImmediately: true
            )
            // Backup channel: write to a per-bundle handoff dir on disk.
            // The primary drains this dir in applicationWillFinishLaunching,
            // which survives the "primary is still launching" race.
            Self.enqueueHandoff(url: url)
            // Terminate is scheduled from applicationDidFinishLaunching.
            return
        }

        if url.scheme == "filesnake" {
            handleActionURL(url)
        } else {
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
    }

    // MARK: - Handoff queue (secondary → primary, disk-backed)

    /// Directory where secondary instances drop URLs the primary couldn't
    /// receive in time. One file per pending URL, deleted after processing.
    private static var handoffDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("Filesnake/pending-opens", isDirectory: true)
    }

    /// Called by a secondary instance when the primary can't receive the
    /// notification yet. Writes the URL string to a uniquely-named file —
    /// the primary will pick it up on its next launch.
    private static func enqueueHandoff(url: URL) {
        let dir = handoffDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(UUID().uuidString).url")
            try url.absoluteString.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Filesnake: failed to enqueue handoff for %@: %@",
                  url.absoluteString, error.localizedDescription)
        }
    }

    /// Called by the primary instance during launch. Reads every queued
    /// URL, dispatches it through the normal open path, then deletes the
    /// file so it isn't replayed on next launch.
    private func drainHandoffQueue() {
        let dir = Self.handoffDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { return }

        for file in files where file.pathExtension == "url" {
            guard let str = try? String(contentsOf: file, encoding: .utf8),
                  let url = URL(string: str) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            try? FileManager.default.removeItem(at: file)
            // Schedule for after launch completes, otherwise handleActionURL
            // runs before `document` is set and filesnake:// URLs get
            // routed against a nil doc.
            DispatchQueue.main.async { [weak self] in
                self?.application(NSApp, open: [url])
            }
        }
    }

    @objc private func receivedOpenFile(_ note: Notification) {
        guard let path = note.object as? String else { return }
        let url = URL(string: path) ?? URL(fileURLWithPath: path)
        Task { @MainActor in
            if url.scheme == "filesnake" {
                self.handleActionURL(url)
            } else {
                self.document?.open(url: url)
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
            }
        }
    }

    func handleActionURL(_ url: URL) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = comps.queryItems else { return }

        let action = comps.host ?? "extract"
        let isBackground = queryItems.first(where: { $0.name == "background" })?.value == "1"
        let dest = queryItems.first(where: { $0.name == "dest" })?.value ?? "here"
        let trash = queryItems.first(where: { $0.name == "trash" })?.value == "1"
        let rawFiles = queryItems
            .filter { $0.name == "file" }
            .compactMap { $0.value }
            .map { URL(fileURLWithPath: $0) }

        // Security gate: only act on files the user actually owns. The Finder
        // extension sends us paths for the Finder selection, so anything
        // outside the home directory is either a crafted filesnake:// URL or
        // a misconfigured Finder selection — either way, refuse. This closes
        // the vector where a malicious link (`filesnake://extract?file=/etc/
        // passwd&trash=1`) could be used to relocate system files to Trash.
        let files = rawFiles.filter { Self.isSafeUserPath($0) }
        if files.count != rawFiles.count {
            NSLog("Filesnake: rejected %d file(s) outside user home for action '%@'",
                  rawFiles.count - files.count, action)
        }

        if isBackground {
            isBackgroundAction = true
            // Close any existing windows so we don't show the main app UI
            for window in NSApp.windows where !(window is NSPanel) {
                window.close()
            }
            NSApp.hide(nil)
        }

        guard !files.isEmpty else { return }
        
        switch action {
        case "extract":
            ArchiveDocument.backgroundExtract(urls: files, dest: dest, trash: trash, appDelegate: self)
        case "compress":
            // Not strictly background extraction, but we can launch the UI for creation
            let doc = ArchiveDocument()
            self.document = doc
            FilesnakeApp.createArchiveFlow(document: doc, predefinedSources: files)
        case "open":
            for f in files {
                let doc = ArchiveDocument()
                doc.open(url: f)
                self.document = doc
                // Show window for this one since it's "Open"
                NSApp.activate(ignoringOtherApps: true)
            }
        case "test":
            ArchiveDocument.testValidity(urls: files, appDelegate: self)
        default:
            break
        }
    }

    /// Returns true iff the resolved, canonical path is inside the user's
    /// home directory. We resolve symlinks so attacks like
    /// `/tmp/mylink -> /etc/passwd` are caught. `/Volumes/*` is also allowed
    /// so the extension still works for archives on external drives.
    private static func isSafeUserPath(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().standardizedFileURL.path
        if resolved.hasPrefix(home + "/") || resolved == home { return true }
        if resolved.hasPrefix("/Volumes/") { return true }
        return false
    }

    func takeoverDefaultApp() {
        Task {
            let types: [UTType] = [
                .zip,
                UTType("public.tar-archive")!,
                UTType("org.gnu.gnu-zip-archive")!,
                UTType("public.bzip2-archive")!,
                UTType("org.tukaani.xz-archive")!,
                UTType("com.rarlab.rar-archive")!,
                UTType("org.7-zip.7-zip-archive")!
            ]
            for type in types {
                do { try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type) } catch { }
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { isPrimary }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        if flag {
            NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
            return false
        } else {
            if let window = NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
                return false
            }
            return true
        }
    }

    func observeSaveProgress(for doc: ArchiveDocument) {
        saveProgressCancellable = Publishers.CombineLatest3(doc.$saveProgress, doc.$isBusy, doc.$saveStatusText)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak doc] progress, isBusy, statusText in
                guard let self = self, let doc = doc else { return }
                
                let isError = statusText.contains("Failed") || statusText.contains("Error") || statusText.contains("Not enough space")
                
                if let p = progress {
                    self.showSavePanel(progress: p, status: statusText)
                } else if isBusy || isError {
                    self.showSavePanel(progress: 0.0, status: statusText.isEmpty ? "Extracting\u{2026}" : statusText)
                } else {
                    self.closeSavePanel()
                }
            }
    }

    private func showSavePanel(progress: Double, status: String) {
        if savePanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 280, height: 60),
                styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.hasShadow = false // Shadow is provided by the SwiftUI view
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.isMovableByWindowBackground = true
            
            if let screen = NSScreen.main {
                let margin: CGFloat = 24
                let screenFrame = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: screenFrame.minX + margin, y: screenFrame.minY + margin))
            }
            
            savePanel = panel
        }
        
        if savePanelHost == nil {
            let host = NSHostingView(rootView: SaveProgressCard(progress: progress, statusText: status))
            savePanel?.contentView = host
            savePanelHost = host
        } else {
            savePanelHost?.rootView = SaveProgressCard(progress: progress, statusText: status)
        }
        
        savePanel?.orderFront(nil)
    }

    private func closeSavePanel() {
        savePanel?.close()
        savePanel = nil
        savePanelHost = nil
    }

    func installDelegatesForOpenWindows() {
        guard let doc = document else { return }
        for window in NSApp.windows {
            if window.delegate is WindowCloseDelegate { continue }
            let delegate = WindowCloseDelegate()
            delegate.onWindowClose = { [weak doc] in
                doc?.close()
            }
            window.delegate = delegate
            windowCloseDelegates[ObjectIdentifier(window)] = delegate
        }
    }
}

final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    var onWindowClose: (() -> Void)?
    func windowWillClose(_ notification: Notification) {
        onWindowClose?()
    }
}
