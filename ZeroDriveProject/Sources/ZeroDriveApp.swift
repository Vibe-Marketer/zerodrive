import SwiftUI
import AppKit

@main
struct ZeroDriveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var lifecycleController = AppLifecycleController.shared
    @StateObject private var supervisor = RcloneDaemonSupervisor.shared
    @StateObject private var spoolManager = SpoolAndGuardManager.shared
    @StateObject private var indexer = RAMTreeIndexer.shared

    var body: some Scene {
        WindowGroup(id: "studio") {
            MainStudioWindow()
                .environmentObject(lifecycleController)
                .environmentObject(supervisor)
                .environmentObject(spoolManager)
                .environmentObject(indexer)
                .frame(minWidth: 940, minHeight: 620)
                .onAppear {
                    lifecycleController.setStudioWindowVisible(true)
                }
                .onDisappear {
                    lifecycleController.setStudioWindowVisible(false)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 660)

        MenuBarExtra("ZeroDrive", systemImage: supervisor.isMounted ? "externaldrive.fill.badge.checkmark" : "externaldrive.fill") {
            MenuBarPopoverView()
                .environmentObject(lifecycleController)
                .environmentObject(supervisor)
                .environmentObject(spoolManager)
                .environmentObject(indexer)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register IOKit pre-sleep power interceptor + wake observer
        RcloneDaemonSupervisor.shared.registerSystemPowerNotifications()

        // Automatically pin ~/ZeroDrive to Finder Sidebar Favorites + install Finder right-click workflows & extension
        RcloneDaemonSupervisor.shared.pinToFinderSidebarIfNeeded()
        RcloneDaemonSupervisor.shared.installFinderWorkflowsAndEnableExtension()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        Task {
            await RcloneDaemonSupervisor.shared.autoMountIfConfigured()
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
                    await SpoolAndGuardManager.shared.handleDroppedURLs(fileURLs, moveAndFreeSpace: true, bypassSpool: false)
                    await RAMTreeIndexer.shared.prewarmAll()
                case "copy":
                    await SpoolAndGuardManager.shared.handleDroppedURLs(fileURLs, moveAndFreeSpace: false, bypassSpool: false)
                    await RAMTreeIndexer.shared.prewarmAll()
                case "retake":
                    let retakesDir = RcloneDaemonSupervisor.shared.mountPoint.appendingPathComponent("_Retakes")
                    try? FileManager.default.createDirectory(at: retakesDir, withIntermediateDirectories: true)
                    for u in fileURLs {
                        try? FileManager.default.moveItem(at: u, to: retakesDir.appendingPathComponent(u.lastPathComponent))
                    }
                    await RAMTreeIndexer.shared.prewarmAll()
                case "evict":
                    let mountPath = RcloneDaemonSupervisor.shared.mountPoint.path + "/"
                    for u in fileURLs {
                        let rel = u.path.replacingOccurrences(of: mountPath, with: "")
                        _ = await RcloneRCClient.shared.forgetFile(relativePath: rel)
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

    @objc private func handleSystemWake() {
        Task {
            await RcloneDaemonSupervisor.shared.healDeadMountAfterSleep()
        }
    }
}
