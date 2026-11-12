import SwiftUI
import AppKit
import FileProvider

@main
struct ZeroDriveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var lifecycleController = AppLifecycleController.shared
    @StateObject private var supervisor = RcloneDaemonSupervisor.shared
    @StateObject private var spoolManager = SpoolAndGuardManager.shared
    @StateObject private var indexer = RAMTreeIndexer.shared
    @StateObject private var turbo = TurboMigrationManager.shared

    var body: some Scene {
        WindowGroup("ZeroDrive", id: "studio") {
            MainStudioWindow()
                .environmentObject(lifecycleController)
                .environmentObject(supervisor)
                .environmentObject(spoolManager)
                .environmentObject(indexer)
                .frame(minWidth: 840, minHeight: 560)
                .onAppear {
                    lifecycleController.setStudioWindowVisible(true)
                }
                .onDisappear {
                    lifecycleController.setStudioWindowVisible(false)
                }
        }
        .defaultSize(width: 960, height: 680)

        Settings {
            AutostartAndWorkflowsView()
                .environmentObject(supervisor)
                .environmentObject(spoolManager)
                .frame(width: 480, height: 360)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var statusTimer: Timer?
    private var sigtermSource: DispatchSourceSignal?
    private var sigintSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        setupStatusItem()

        RcloneDaemonSupervisor.shared.registerSystemPowerNotifications()
        RcloneDaemonSupervisor.shared.installFinderWorkflowsAndEnableExtension()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        setupTerminationSignalTrap()

        Task {
            await ManageFileProvider.shared.registerDomainIfNeeded()
            await RcloneDaemonSupervisor.shared.autoMountIfConfigured()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where !(window is NSPanel) {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = item

        if let button = item.button {
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            let image = NSImage(systemSymbolName: "externaldrive.fill.badge.checkmark", accessibilityDescription: "ZeroDrive")?.withSymbolConfiguration(symbolConfig)
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
            button.toolTip = "ZeroDrive: Cloud Vault"
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        let popoverContent = MenuBarPopoverView()
            .environmentObject(AppLifecycleController.shared)
            .environmentObject(RcloneDaemonSupervisor.shared)
            .environmentObject(SpoolAndGuardManager.shared)
            .environmentObject(RAMTreeIndexer.shared)
        pop.contentViewController = NSHostingController(rootView: popoverContent)
        self.popover = pop

        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusItem()
            }
        }
    }

    @MainActor
    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let turbo = TurboMigrationManager.shared
        let spool = SpoolAndGuardManager.shared
        let supervisor = RcloneDaemonSupervisor.shared

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)

        let upSpeed = max(turbo.telemetry.isRunning ? turbo.telemetry.speedMBps : 0, spool.telemetry.uploadSpeedMBps)
        let downSpeed = spool.telemetry.downloadSpeedMBps

        if upSpeed > 0.05 && downSpeed > 0.05 {
            let img = NSImage(systemSymbolName: "arrow.up.arrow.down.circle.fill", accessibilityDescription: "ZeroDrive Active")?.withSymbolConfiguration(symbolConfig)
            img?.isTemplate = true
            button.image = img
            button.title = String(format: " ↑%.1f ↓%.1f", upSpeed, downSpeed)
        } else if upSpeed > 0.05 {
            let img = NSImage(systemSymbolName: "arrow.up.icloud.fill", accessibilityDescription: "ZeroDrive Uploading")?.withSymbolConfiguration(symbolConfig)
            img?.isTemplate = true
            button.image = img
            button.title = String(format: " ↑ %.1f MB/s", upSpeed)
        } else if downSpeed > 0.05 {
            let img = NSImage(systemSymbolName: "arrow.down.icloud.fill", accessibilityDescription: "ZeroDrive Downloading")?.withSymbolConfiguration(symbolConfig)
            img?.isTemplate = true
            button.image = img
            button.title = String(format: " ↓ %.1f MB/s", downSpeed)
        } else if spool.dirtyFileCount > 0 {
            let img = NSImage(systemSymbolName: "arrow.up.icloud.fill", accessibilityDescription: "ZeroDrive Syncing")?.withSymbolConfiguration(symbolConfig)
            img?.isTemplate = true
            button.image = img
            button.title = " ↑ \(spool.dirtyFileCount)"
        } else {
            let imgName = supervisor.isMounted ? "externaldrive.fill.badge.checkmark" : "externaldrive.fill"
            let img = NSImage(systemSymbolName: imgName, accessibilityDescription: "ZeroDrive")?.withSymbolConfiguration(symbolConfig)
            img?.isTemplate = true
            button.image = img
            button.title = ""
        }
    }

    @objc private func handleStatusItemClick(_ sender: AnyObject?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            let menu = NSMenu()

            let dashItem = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboardFromMenu), keyEquivalent: "o")
            dashItem.target = self
            menu.addItem(dashItem)

            let searchItem = NSMenuItem(title: "Global Search…", action: #selector(openSearchFromMenu), keyEquivalent: "s")
            searchItem.target = self
            menu.addItem(searchItem)

            let finderItem = NSMenuItem(title: "Open My Drive in Finder", action: #selector(openFinderFromMenu), keyEquivalent: "f")
            finderItem.target = self
            menu.addItem(finderItem)

            menu.addItem(NSMenuItem.separator())

            let dupItem = NSMenuItem(title: "Duplicate Protection…", action: #selector(openDuplicatesFromMenu), keyEquivalent: "d")
            dupItem.target = self
            menu.addItem(dupItem)

            let licItem = NSMenuItem(title: "Account & Licensing…", action: #selector(openLicensingFromMenu), keyEquivalent: "l")
            licItem.target = self
            menu.addItem(licItem)

            menu.addItem(NSMenuItem.separator())

            let quitItem = NSMenuItem(title: "Quit ZeroDrive", action: #selector(quitFromMenu), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)

            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            guard let button = statusItem?.button, let popover = popover else { return }
            if popover.isShown {
                popover.performClose(sender)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                popover.contentViewController?.view.window?.makeKey()
            }
        }
    }

    @objc private func openDashboardFromMenu() {
        AppLifecycleController.shared.setStudioWindowVisible(true)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSearchFromMenu() {
        AppLifecycleController.shared.setStudioWindowVisible(true)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openFinderFromMenu() {
        RcloneDaemonSupervisor.shared.openInFinder(RcloneDaemonSupervisor.shared.mountPoint.appendingPathComponent("My Drive"))
    }

    @objc private func openDuplicatesFromMenu() {
        AppLifecycleController.shared.setStudioWindowVisible(true)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openLicensingFromMenu() {
        AppLifecycleController.shared.setStudioWindowVisible(true)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    private func setupTerminationSignalTrap() {
        let sigQueue = DispatchQueue(label: "co.aisimple.zerodrive.signals", qos: .userInteractive)
        signal(SIGTERM, SIG_IGN)
        let termSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: sigQueue)
        termSrc.setEventHandler {
            RcloneDaemonSupervisor.handlePreSleepSynchronousUnmount()
            _exit(0)
        }
        termSrc.resume()
        self.sigtermSource = termSrc

        signal(SIGINT, SIG_IGN)
        let intSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: sigQueue)
        intSrc.setEventHandler {
            RcloneDaemonSupervisor.handlePreSleepSynchronousUnmount()
            _exit(0)
        }
        intSrc.resume()
        self.sigintSource = intSrc
    }

    // MARK: - Native macOS Finder Services

    private func extractURLs(from pboard: NSPasteboard) -> [URL] {
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            return urls
        }
        if let paths = pboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        return []
    }

    @objc func moveToZeroDriveService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = extractURLs(from: pboard)
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            TurboMigrationManager.shared.startDirectMove(urls: urls)
            await RAMTreeIndexer.shared.prewarmAll()
        }
    }

    @objc func copyToZeroDriveService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = extractURLs(from: pboard)
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            await SpoolAndGuardManager.shared.handleDroppedURLs(urls, moveAndFreeSpace: false, bypassSpool: false)
            await RAMTreeIndexer.shared.prewarmAll()
        }
    }

    @objc func moveToRetakesService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = extractURLs(from: pboard)
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            let retakesDir = RcloneDaemonSupervisor.shared.mountPoint.appendingPathComponent("My Drive/_Retakes")
            try? FileManager.default.createDirectory(at: retakesDir, withIntermediateDirectories: true)
            for u in urls {
                let dst = retakesDir.appendingPathComponent(u.lastPathComponent)
                if FileManager.default.fileExists(atPath: dst.path) {
                    try? FileManager.default.removeItem(at: dst)
                }
                let cp = Process()
                cp.executableURL = URL(fileURLWithPath: "/bin/cp")
                cp.arguments = ["-R", "-X", u.path, dst.path]
                try? cp.run()
                cp.waitUntilExit()
                if cp.terminationStatus == 0 {
                    try? FileManager.default.removeItem(at: u)
                }
            }
            await RAMTreeIndexer.shared.prewarmAll()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "zerodrive" {
            if url.host == "open" {
                AppLifecycleController.shared.setStudioWindowVisible(true)
                continue
            }
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
            let cmd = components.queryItems?.first(where: { $0.name == "cmd" })?.value ?? "move"
            let paths = components.queryItems?.filter({ $0.name == "path" }).compactMap({ $0.value }) ?? []
            let fileURLs = paths.map { URL(fileURLWithPath: $0) }
            guard !fileURLs.isEmpty else { continue }

            Task { @MainActor in
                switch cmd {
                case "move":
                    TurboMigrationManager.shared.startDirectMove(urls: fileURLs)
                    await RAMTreeIndexer.shared.prewarmAll()
                case "copy":
                    await SpoolAndGuardManager.shared.handleDroppedURLs(fileURLs, moveAndFreeSpace: false, bypassSpool: false)
                    await RAMTreeIndexer.shared.prewarmAll()
                case "retake":
                    let retakesDir = RcloneDaemonSupervisor.shared.mountPoint.appendingPathComponent("My Drive/_Retakes")
                    try? FileManager.default.createDirectory(at: retakesDir, withIntermediateDirectories: true)
                    for u in fileURLs {
                        let dst = retakesDir.appendingPathComponent(u.lastPathComponent)
                        if FileManager.default.fileExists(atPath: dst.path) {
                            try? FileManager.default.removeItem(at: dst)
                        }
                        let cp = Process()
                        cp.executableURL = URL(fileURLWithPath: "/bin/cp")
                        cp.arguments = ["-R", "-X", u.path, dst.path]
                        try? cp.run()
                        cp.waitUntilExit()
                        if cp.terminationStatus == 0 {
                            try? FileManager.default.removeItem(at: u)
                        }
                    }
                    await RAMTreeIndexer.shared.prewarmAll()
                case "evict":
                    let mountPath = RcloneDaemonSupervisor.shared.mountPoint.path + "/"
                    let cachePath = RcloneDaemonSupervisor.shared.cacheDir.appendingPathComponent("vfs/ZeroDriveUnified").path + "/"
                    for u in fileURLs {
                        let rel = u.path.replacingOccurrences(of: mountPath, with: "")
                        _ = await RcloneRCClient.shared.forgetFile(relativePath: rel)
                        let localCachedFile = cachePath + rel
                        if FileManager.default.fileExists(atPath: localCachedFile) {
                            try? FileManager.default.removeItem(atPath: localCachedFile)
                        }
                        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("ZeroDrive"), displayName: "ZeroDrive")
                        try? await NSFileProviderManager(for: domain)?.evictItem(withIdentifier: NSFileProviderItemIdentifier(rel))
                    }
                case "pin":
                    Task.detached(priority: .utility) {
                        for u in fileURLs {
                            // Touch / read through mount to pull chunks into local VFS cache
                            if let handle = try? FileHandle(forReadingFrom: u) {
                                _ = handle.readData(ofLength: 128 * 1024)
                                try? handle.close()
                            }
                        }
                    }
                default:
                    break
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return AppLifecycleController.shared.handleApplicationTerminationRequest()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppLifecycleController.shared.setStudioWindowVisible(true)
        if !flag {
            for window in sender.windows {
                if window.canBecomeMain {
                    window.makeKeyAndOrderFront(self)
                    break
                }
            }
        }
        return true
    }

    @objc private func handleSystemWake() {
        Task {
            await RcloneDaemonSupervisor.shared.healDeadMountAfterSleep()
        }
    }
}
