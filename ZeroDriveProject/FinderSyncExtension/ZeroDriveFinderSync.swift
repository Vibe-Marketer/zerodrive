import Cocoa
import FinderSync

@objc(FinderSyncExtension)
public final class FinderSyncExtension: FIFinderSync {

    private let zeroDriveRoot: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("ZeroDrive")
    }()

    public override init() {
        super.init()
        let home = FileManager.default.homeDirectoryForCurrentUser
        var watchedDirs: Set<URL> = [
            home,
            zeroDriveRoot,
            home.appendingPathComponent("Library/CloudStorage"),
            home.appendingPathComponent("Library/CloudStorage/FabricDrive"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Documents"),
            URL(fileURLWithPath: "/Volumes")
        ]
        if let cloudDirs = try? FileManager.default.contentsOfDirectory(at: home.appendingPathComponent("Library/CloudStorage"), includingPropertiesForKeys: nil) {
            for dir in cloudDirs {
                watchedDirs.insert(dir)
            }
        }
        FIFinderSyncController.default().directoryURLs = watchedDirs

        if let cloudIcon = NSImage(systemSymbolName: "checkmark.icloud.fill", accessibilityDescription: "Synced in ZeroDrive") {
            FIFinderSyncController.default().setBadgeImage(cloudIcon, label: "ZeroDrive Cloud", forBadgeIdentifier: "cloud_synced")
        }
    }

    public override var toolbarItemName: String {
        return "ZeroDrive"
    }

    public override var toolbarItemToolTip: String {
        return "ZeroDrive Quick Actions — Move or Copy files to your 5 TB Cloud Vault"
    }

    public override var toolbarItemImage: NSImage {
        return NSImage(systemSymbolName: "externaldrive.fill.badge.icloud", accessibilityDescription: "ZeroDrive") ?? NSImage()
    }

    public override func requestBadgeIdentifier(for url: URL) {
        if url.path.hasPrefix(zeroDriveRoot.path) {
            FIFinderSyncController.default().setBadgeIdentifier("cloud_synced", for: url)
        }
    }

    public override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "ZeroDrive")

        let moveItem = NSMenuItem(
            title: "ZeroDrive: Move to Cloud & Free Mac Space",
            action: #selector(moveToZeroDrive(_:)),
            keyEquivalent: ""
        )
        moveItem.target = self
        moveItem.image = NSImage(systemSymbolName: "arrow.up.doc.fill", accessibilityDescription: nil)
        menu.addItem(moveItem)

        let copyItem = NSMenuItem(
            title: "ZeroDrive: Copy to 5 TB Cloud Vault",
            action: #selector(copyToZeroDrive(_:)),
            keyEquivalent: ""
        )
        copyItem.target = self
        copyItem.image = NSImage(systemSymbolName: "doc.on.doc.fill", accessibilityDescription: nil)
        menu.addItem(copyItem)

        let retakeItem = NSMenuItem(
            title: "ZeroDrive: Move to _Retakes Folder",
            action: #selector(moveToRetakes(_:)),
            keyEquivalent: ""
        )
        retakeItem.target = self
        retakeItem.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        menu.addItem(retakeItem)

        let evictItem = NSMenuItem(
            title: "ZeroDrive: Free Local Cache Copy",
            action: #selector(evictLocalCopy(_:)),
            keyEquivalent: ""
        )
        evictItem.target = self
        evictItem.image = NSImage(systemSymbolName: "trash.slash.fill", accessibilityDescription: nil)
        menu.addItem(evictItem)

        let openItem = NSMenuItem(
            title: "Open ZeroDrive Studio",
            action: #selector(openStudio(_:)),
            keyEquivalent: ""
        )
        openItem.target = self
        openItem.image = NSImage(systemSymbolName: "externaldrive.fill.badge.icloud", accessibilityDescription: nil)
        menu.addItem(openItem)

        return menu
    }

    @objc private func moveToZeroDrive(_ sender: AnyObject?) {
        dispatchFinderAction("move")
    }

    @objc private func copyToZeroDrive(_ sender: AnyObject?) {
        dispatchFinderAction("copy")
    }

    @objc private func moveToRetakes(_ sender: AnyObject?) {
        dispatchFinderAction("retake")
    }

    @objc private func evictLocalCopy(_ sender: AnyObject?) {
        dispatchFinderAction("evict")
    }

    @objc private func openStudio(_ sender: AnyObject?) {
        if let url = URL(string: "zerodrive://open") {
            NSWorkspace.shared.open(url)
        }
    }

    private func dispatchFinderAction(_ cmd: String) {
        let selected = FIFinderSyncController.default().selectedItemURLs() ?? []
        let target = FIFinderSyncController.default().targetedURL()
        let urls = selected.isEmpty ? (target.map { [$0] } ?? []) : selected
        guard !urls.isEmpty else { return }

        var components = URLComponents()
        components.scheme = "zerodrive"
        components.host = "finder-action"
        var queryItems = [URLQueryItem(name: "cmd", value: cmd)]
        for u in urls {
            queryItems.append(URLQueryItem(name: "path", value: u.path))
        }
        components.queryItems = queryItems
        if let actionURL = components.url {
            NSWorkspace.shared.open(actionURL)
        }
    }
}
