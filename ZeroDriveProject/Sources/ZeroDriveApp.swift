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
        // Main Tangible Desktop Studio Window (860x560pt)
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

        // Menu Bar Extra Daemon (Always running in the background)
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

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // Auto-mount on launch if a valid rclone.conf with [ZeroDriveUnified] exists
        Task {
            await RcloneDaemonSupervisor.shared.autoMountIfConfigured()
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
