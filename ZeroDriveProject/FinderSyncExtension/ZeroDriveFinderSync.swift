import Cocoa
import FinderSync

@objc(FinderSyncExtension)
public final class FinderSyncExtension: FIFinderSync {

    private let defaultBaseURL = "https://api.zerodrive.dev"
    private let fallbackToken = "zd_sec_b07b3671b1c45b32195f8353d4df8945ee31448699a361b32b6f8192a9b03633"

    private let zeroDriveRoot: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".zerodrive-mount/My Drive")
    }()

    public override init() {
        super.init()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let watchedDirs: Set<URL> = [
            zeroDriveRoot,
            home.appendingPathComponent("ZeroDrive")
        ]
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

        let agentLinkItem = NSMenuItem(
            title: "Copy 24-Hour Agent Link",
            action: #selector(copyAgentLink(_:)),
            keyEquivalent: ""
        )
        agentLinkItem.target = self
        agentLinkItem.image = NSImage(systemSymbolName: "bolt.badge.clock.fill", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "link.badge.plus", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        menu.addItem(agentLinkItem)

        let streamUrlItem = NSMenuItem(
            title: "Copy Public Stream URL",
            action: #selector(copyPublicStreamURL(_:)),
            keyEquivalent: ""
        )
        streamUrlItem.target = self
        streamUrlItem.image = NSImage(systemSymbolName: "play.rectangle.on.rectangle.fill", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        menu.addItem(streamUrlItem)

        menu.addItem(NSMenuItem.separator())

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

        menu.addItem(NSMenuItem.separator())

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

    // MARK: - Context Menu Actions

    @objc private func copyAgentLink(_ sender: AnyObject?) {
        copySharingLink(actionTitle: "Copy 24-Hour Agent Link", isStream: false)
    }

    @objc private func copyPublicStreamURL(_ sender: AnyObject?) {
        copySharingLink(actionTitle: "Copy Public Stream URL", isStream: true)
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

    // MARK: - Sharing Logic

    private func getSelectedURLs() -> [URL] {
        let selected = FIFinderSyncController.default().selectedItemURLs() ?? []
        if !selected.isEmpty {
            return selected
        }
        if let target = FIFinderSyncController.default().targetedURL() {
            return [target]
        }
        return []
    }

    private func resolveVaultRelativePath(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidateRoots = [
            "\(home)/Library/CloudStorage/ZeroDrive-ZeroDrive",
            "\(home)/ZeroDrive",
            "\(home)/.zerodrive-mount/My Drive",
            "\(home)/.zerodrive-mount",
            "\(home)/Library/CloudStorage/FabricDrive"
        ]

        let fullPath = url.path
        let resolvedPath = url.resolvingSymlinksInPath().path

        for root in candidateRoots {
            let standardRoot = (root as NSString).standardizingPath
            if resolvedPath.hasPrefix(standardRoot) {
                let sub = String(resolvedPath.dropFirst(standardRoot.count))
                let trimmed = sub.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
            if fullPath.hasPrefix(standardRoot) {
                let sub = String(fullPath.dropFirst(standardRoot.count))
                let trimmed = sub.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        return url.lastPathComponent
    }

    private func resolveAuthToken() -> String {
        if let groupDefaults = UserDefaults(suiteName: "group.co.aisimple.zerodrive"),
           let token = groupDefaults.string(forKey: "api_token"),
           !token.isEmpty {
            return token
        }
        if let standardToken = UserDefaults.standard.string(forKey: "api_token"),
           !standardToken.isEmpty {
            return standardToken
        }
        if let envToken = ProcessInfo.processInfo.environment["ZERODRIVE_API_TOKEN"],
           !envToken.isEmpty {
            return envToken
        }
        return fallbackToken
    }

    private func fetchSignedDownloadURL(relativePath: String, completion: @escaping (String?) -> Void) {
        var components = URLComponents(string: "\(defaultBaseURL)/v1/files/download-url")
        components?.queryItems = [
            URLQueryItem(name: "path", value: relativePath)
        ]

        guard let apiURL = components?.url else {
            completion(nil)
            return
        }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 8.0
        let token = resolveAuthToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("ZeroDrive-FinderSync/3.0", forHTTPHeaderField: "User-Agent")

        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let data = data,
                  let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dlUrl = json["download_url"] as? String,
                  !dlUrl.isEmpty else {
                completion(nil)
                return
            }
            completion(dlUrl)
        }
        task.resume()
    }

    private func copySharingLink(actionTitle: String, isStream: Bool) {
        let urls = getSelectedURLs()
        guard !urls.isEmpty else {
            notifyUser(title: "ZeroDrive", message: "No file selected in Finder.", sound: false)
            return
        }

        let dispatchGroup = DispatchGroup()
        var results: [(index: Int, link: String)] = []
        let lock = NSLock()

        for (index, url) in urls.enumerated() {
            let relativePath = resolveVaultRelativePath(for: url)
            dispatchGroup.enter()
            fetchSignedDownloadURL(relativePath: relativePath) { downloadURL in
                let finalURL: String
                if let downloadURL = downloadURL, !downloadURL.isEmpty {
                    finalURL = downloadURL
                } else {
                    let encoded = relativePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? relativePath
                    finalURL = "https://api.zerodrive.dev/vault/download?path=\(encoded)"
                }
                lock.lock()
                results.append((index: index, link: finalURL))
                lock.unlock()
                dispatchGroup.leave()
            }
        }

        dispatchGroup.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            let sortedLinks = results.sorted(by: { $0.index < $1.index }).map { $0.link }
            let joinedText = sortedLinks.joined(separator: "\n")

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(joinedText, forType: .string)

            let notifTitle = isStream ? "ZeroDrive Public Stream URL Copied" : "ZeroDrive 24-Hour Agent Link Copied"
            let notifMessage: String
            if urls.count == 1 {
                let name = urls[0].lastPathComponent
                notifMessage = isStream
                    ? "Public streaming URL for '\(name)' copied to clipboard."
                    : "24-Hour agent download link for '\(name)' copied to clipboard."
            } else {
                notifMessage = "\(urls.count) sharing links copied to clipboard."
            }

            self.notifyUser(title: notifTitle, message: notifMessage, sound: true)
        }
    }

    private func notifyUser(title: String, message: String, sound: Bool) {
        if sound {
            if NSSound(named: "Glass")?.play() != true {
                NSSound.beep()
            }
        }

        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = message
        if sound {
            notification.soundName = NSUserNotificationDefaultSoundName
        }
        NSUserNotificationCenter.default.deliver(notification)
        NSLog("[ZeroDriveFinderSync] %@: %@", title, message)
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
