import Foundation
import FinderSync

class FilesnakeFinderSync: FIFinderSync {
    
    override init() {
        super.init()
        // Register our extension for all folders
        let center = FIFinderSyncController.default()
        center.directoryURLs = [URL(fileURLWithPath: "/")]
    }
    
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        // We only care about the contextual menu for items
        guard menuKind == .contextualMenuForItems else { return nil }
        
        // Check if selected items are archives
        guard let items = FIFinderSyncController.default().selectedItemURLs() else { return nil }
        
        let validExtensions = ["zip", "rar", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "7z"]
        let allArchives = items.allSatisfy { validExtensions.contains($0.pathExtension.lowercased()) }
        
        guard !items.isEmpty else { return nil }
        
        let menu = NSMenu(title: "")
        let rootItem = NSMenuItem(title: "Filesnake", action: nil, keyEquivalent: "")
        
        // Use the app icon if possible
        let appBundleURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if let img = NSImage(contentsOfFile: appBundleURL.appendingPathComponent("Contents/Resources/AppIcon.icns").path) {
            img.size = NSSize(width: 16, height: 16)
            rootItem.image = img
        }
        
        let submenu = NSMenu(title: "Filesnake")
        
        func addHeader(title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            item.attributedTitle = NSAttributedString(string: title, attributes: attrs)
            item.isEnabled = false
            submenu.addItem(item)
        }
        
        // Extract & Trash at the very top
        if allArchives {
            submenu.addItem(withTitle: "Extract & Trash", action: #selector(extractAndTrash(_:)), keyEquivalent: "")
            
            // Section 1: Extract to
            addHeader(title: "Extract to")
            submenu.addItem(withTitle: "Desktop", action: #selector(extractToDesktop(_:)), keyEquivalent: "")
            submenu.addItem(withTitle: "Documents", action: #selector(extractToDocuments(_:)), keyEquivalent: "")
            submenu.addItem(withTitle: "Downloads", action: #selector(extractToDownloads(_:)), keyEquivalent: "")
            submenu.addItem(withTitle: "Select...", action: #selector(extractToSelect(_:)), keyEquivalent: "")
        }
        if allArchives {
            // Section 3: Other Actions
            addHeader(title: "Other Actions")
            submenu.addItem(withTitle: "Test Validity of Archives", action: #selector(testValidity(_:)), keyEquivalent: "")
        }
        
        rootItem.submenu = submenu
        menu.addItem(rootItem)
        
        return menu
    }
    
    @objc func testValidity(_ sender: AnyObject?) {
        sendAction(to: "here", actionName: "test", delete: false)
    }
    
    @objc func extractToDesktop(_ sender: AnyObject?) {
        sendAction(to: "desktop", actionName: "extract", delete: false)
    }
    
    @objc func extractToDocuments(_ sender: AnyObject?) {
        sendAction(to: "documents", actionName: "extract", delete: false)
    }
    
    @objc func extractToDownloads(_ sender: AnyObject?) {
        sendAction(to: "downloads", actionName: "extract", delete: false)
    }
    
    @objc func extractToSelect(_ sender: AnyObject?) {
        sendAction(to: "select", actionName: "extract", delete: false)
    }
    
    @objc func extractAndTrash(_ sender: AnyObject?) {
        sendAction(to: "here", actionName: "extract", delete: true)
    }
    
    private func sendAction(to dest: String, actionName: String, delete: Bool, clean: Bool = false) {
        guard let items = FIFinderSyncController.default().selectedItemURLs() else { return }
        
        // Use URL scheme to tell main app to extract
        var comps = URLComponents()
        comps.scheme = "filesnake"
        comps.host = actionName
        
        var queryItems = [URLQueryItem]()
        queryItems.append(URLQueryItem(name: "dest", value: dest))
        queryItems.append(URLQueryItem(name: "trash", value: delete ? "1" : "0"))
        queryItems.append(URLQueryItem(name: "clean", value: clean ? "1" : "0"))
        queryItems.append(URLQueryItem(name: "background", value: "1"))
        
        for item in items {
            queryItems.append(URLQueryItem(name: "file", value: item.path))
        }
        
        comps.queryItems = queryItems
        
        if let url = comps.url {
            NSWorkspace.shared.open(url)
        }
    }
}
