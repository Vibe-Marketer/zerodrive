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
                .frame(minWidth: 740, minHeight: 480)
                .onAppear {
                    lifecycleController.setStudioWindowVisible(true)
                }
                .onDisappear {
                    lifecycleController.setStudioWindowVisible(false)
                }
        }
        .defaultSize(width: 820, height: 540)

        Settings {
            AutostartAndWorkflowsView()
                .environmentObject(supervisor)
                .environmentObject(spoolManager)
                .frame(width: 480, height: 360)
        }

        MenuBarExtra {
            MenuBarPopoverView()
                .environmentObject(lifecycleController)
                .environmentObject(supervisor)
                .environmentObject(spoolManager)
                .environmentObject(indexer)
        } label: {
            HStack(spacing: 4) {
                let isBusy = turbo.telemetry.isRunning || spoolManager.dirtyFileCount > 0
                Image(systemName: isBusy ? "arrow.up.icloud.fill" : (supervisor.isMounted ? "externaldrive.fill.badge.checkmark" : "externaldrive.fill"))
                if turbo.telemetry.isRunning && turbo.telemetry.speedMBps > 0.1 {
                    Text(String(format: "↑ %.1f MB/s", turbo.telemetry.speedMBps))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                } else if spoolManager.dirtyFileCount > 0 && spoolManager.telemetry.uploadSpeedMBps > 0.05 {
                    Text(String(format: "↑ %.1f MB/s", spoolManager.telemetry.uploadSpeedMBps))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

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
    }

    private func setupTerminationSignalTrap() {
        signal(SIGTERM, SIG_IGN)
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource.setEventHandler {
            RcloneDaemonSupervisor.handlePreSleepSynchronousUnmount()
            exit(0)
        }
        sigtermSource.resume()

        signal(SIGINT, SIG_IGN)
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler {
            RcloneDaemonSupervisor.handlePreSleepSynchronousUnmount()
            exit(0)
        }
        sigintSource.resume()
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
                    for u in fileURLs {
                        let rel = u.path.replacingOccurrences(of: mountPath, with: "")
                        _ = await RcloneRCClient.shared.forgetFile(relativePath: rel)
                        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("ZeroDrive"), displayName: "ZeroDrive")
                        try? await NSFileProviderManager(for: domain)?.evictItem(withIdentifier: NSFileProviderItemIdentifier(rel))
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
