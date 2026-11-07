import SwiftUI
import AppKit

@MainActor
public final class AppLifecycleController: ObservableObject {
    public static let shared = AppLifecycleController()

    @Published public private(set) var isStudioWindowOpen: Bool = true
    @Published public var showOnboardingSheet: Bool = false

    private init() {
        setStudioWindowVisible(true)
        if !MultiCloudCombineBuilder.shared.hasConfiguredPrimaryVault() {
            showOnboardingSheet = true
        }
    }

    public func setStudioWindowVisible(_ visible: Bool) {
        self.isStudioWindowOpen = visible
        // Always keep .regular activation policy so the Dock icon remains visible
        // and clicking ZeroDrive in Dock/Spotlight always reopens the window.
        NSApp.setActivationPolicy(.regular)
        if visible {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Guards manual Unmount requests when dirty files exist in ~/.zerodrive-cache
    public func requestSafeUnmount() {
        let spool = SpoolAndGuardManager.shared
        let dirtyCount = spool.dirtyFileCount

        guard dirtyCount > 0 else {
            Task {
                await RcloneDaemonSupervisor.shared.unmountCleanly()
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = "Cannot Unmount: \(dirtyCount) Unsynced Files in Local Spool"
        alert.informativeText = "You have \(ByteCountFormatter.string(fromByteCount: spool.dirtyBytes, countStyle: .file)) queued or actively uploading in ~/.zerodrive-cache. Unmounting now will pause uploads until you remount."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Sync Now & Unmount When Done")
        alert.addButton(withTitle: "Pause Uploads & Unmount Now")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            Task {
                await spool.flushQueueImmediately()
                while spool.dirtyFileCount > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                await RcloneDaemonSupervisor.shared.unmountCleanly()
            }
        case .alertSecondButtonReturn:
            Task {
                await RcloneDaemonSupervisor.shared.unmountCleanly()
            }
        default:
            break
        }
    }

    public func handleApplicationTerminationRequest() -> NSApplication.TerminateReply {
        let spool = SpoolAndGuardManager.shared
        let turbo = TurboMigrationManager.shared
        let dirtyCount = spool.dirtyFileCount
        // Only warn if a LOCAL migration is running on this Mac (remote streams on naegele-mm keep running independently)
        let isLocalMigrating = turbo.isLocalTransferRunning

        guard dirtyCount > 0 || isLocalMigrating else {
            Task {
                await RcloneDaemonSupervisor.shared.unmountCleanly()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }

        let alert = NSAlert()
        if isLocalMigrating {
            alert.messageText = "ZeroDrive: Local Transfer In Progress (\(turbo.telemetry.spaceName))"
            alert.informativeText = "A transfer is actively moving files from this Mac to ZeroDrive. Quitting now will stop the local transfer."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Cancel Quit & Continue Transfer")
            alert.addButton(withTitle: "Stop Local Transfer & Quit Now")
        } else {
            alert.messageText = "ZeroDrive: \(dirtyCount) Unsynced Files in Local Spool"
            alert.informativeText = "You have files queued or actively uploading to your cloud storage in ~/.zerodrive-cache (\(ByteCountFormatter.string(fromByteCount: spool.dirtyBytes, countStyle: .file))). Quitting now could interrupt active transfers."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Wait & Quit Automatically When Done")
            alert.addButton(withTitle: "Keep in Local Spool & Quit Now (Resumes Next Launch)")
            alert.addButton(withTitle: "Cancel")
        }

        let response = alert.runModal()
        if isLocalMigrating {
            switch response {
            case .alertSecondButtonReturn:
                turbo.cancelLocalOnly()
                Task {
                    await RcloneDaemonSupervisor.shared.unmountCleanly()
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
                return .terminateLater
            default:
                return .terminateCancel
            }
        }

        switch response {
        case .alertFirstButtonReturn:
            Task {
                await spool.flushQueueImmediately()
                var waitCount = 0
                while spool.dirtyFileCount > 0 && waitCount < 120 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    waitCount += 1
                }
                await RcloneDaemonSupervisor.shared.unmountCleanly()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater

        case .alertSecondButtonReturn:
            Task {
                await RcloneDaemonSupervisor.shared.unmountCleanly()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater

        default:
            return .terminateCancel
        }
    }
}
