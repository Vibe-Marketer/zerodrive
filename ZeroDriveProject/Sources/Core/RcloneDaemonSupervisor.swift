import Foundation
import AppKit
import IOKit
import IOKit.pwr_mgt

// IOKit C-callback for intercepting system sleep BEFORE kernel network stack halts
private func zeroDrivePowerCallback(
    refCon: UnsafeMutableRawPointer?,
    service: io_service_t,
    messageType: natural_t,
    messageArgument: UnsafeMutableRawPointer?
) {
    let kIOMessageCanSystemSleepValue: UInt32 = 0xe0000270
    let kIOMessageSystemWillSleepValue: UInt32 = 0xe0000280
    let kIOMessageSystemHasPoweredOnValue: UInt32 = 0xe0000300

    switch messageType {
    case kIOMessageCanSystemSleepValue:
        IOAllowPowerChange(RcloneDaemonSupervisor.powerRootPort, Int(bitPattern: messageArgument))

    case kIOMessageSystemWillSleepValue:
        // Synchronously unmount loopback NFS BEFORE the network interface dies to prevent Kernel D-State lock
        RcloneDaemonSupervisor.handlePreSleepSynchronousUnmount()
        IOAllowPowerChange(RcloneDaemonSupervisor.powerRootPort, Int(bitPattern: messageArgument))

    case kIOMessageSystemHasPoweredOnValue:
        Task { @MainActor in
            await RcloneDaemonSupervisor.shared.healDeadMountAfterSleep()
        }

    default:
        break
    }
}

@MainActor
public final class RcloneDaemonSupervisor: ObservableObject {
    public static let shared = RcloneDaemonSupervisor()

    nonisolated(unsafe) public static var powerRootPort: io_connect_t = 0
    nonisolated(unsafe) private static var powerNotifierObject: io_object_t = 0
    nonisolated(unsafe) private static var powerNotifyPortRef: IONotificationPortRef?
    nonisolated(unsafe) private static var wasMountedBeforeSleep: Bool = false

    @Published public private(set) var isMounted: Bool = false
    @Published public private(set) var isBusy: Bool = false
    @Published public private(set) var statusMessage: String = "Ready"
    @Published public var boostVideoBufferEnabled: Bool = false

    public let mountPoint: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("ZeroDrive")
    }()

    public let cacheDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".zerodrive-cache")
    }()

    private var rcloneProcess: Process?
    private var healthMonitorTask: Task<Void, Never>?

    public func registerSystemPowerNotifications() {
        guard Self.powerRootPort == 0 else { return }
        Self.powerRootPort = IORegisterForSystemPower(
            nil,
            &Self.powerNotifyPortRef,
            zeroDrivePowerCallback,
            &Self.powerNotifierObject
        )
        if Self.powerRootPort != 0, let portRef = Self.powerNotifyPortRef {
            CFRunLoopAddSource(
                CFRunLoopGetMain(),
                IONotificationPortGetRunLoopSource(portRef).takeUnretainedValue(),
                CFRunLoopMode.commonModes
            )
        }
    }

    nonisolated public static func handlePreSleepSynchronousUnmount() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let mountPath = home.appendingPathComponent("ZeroDrive").path
        let task1 = Process()
        task1.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task1.arguments = ["unmount", "force", mountPath]
        try? task1.run()
        task1.waitUntilExit()

        let task2 = Process()
        task2.executableURL = URL(fileURLWithPath: "/sbin/umount")
        task2.arguments = ["-f", mountPath]
        try? task2.run()
        task2.waitUntilExit()
    }

    public func autoMountIfConfigured() async {
        guard MultiCloudCombineBuilder.shared.hasConfiguredPrimaryVault() else {
            statusMessage = "Setup Required — Configure Primary Vault"
            return
        }
        await mountUnifiedDrive()
    }

    public func mountUnifiedDrive() async {
        guard !isMounted, !isBusy else { return }
        isBusy = true
        statusMessage = "Cleaning stale NFS mounts..."

        // [Mandatory Step 1] Force clean any dead/ghost NFS mounts
        await forceCleanStaleMounts()

        statusMessage = "Locating & verifying rclone nfsmount engine..."
        guard let rcloneURL = await resolveOrDownloadRcloneBinary() else {
            statusMessage = "rclone engine missing — click Download Official Engine"
            isBusy = false
            return
        }

        // Ensure [ZeroDriveUnified] exists in ~/.config/rclone/rclone.conf
        if !MultiCloudCombineBuilder.shared.hasConfiguredPrimaryVault() {
            if let provisioned = try? await DFYProvisioningClient.shared.provisionVault(email: "trial@zerodrive.aisimple.co", licenseKey: "TRIAL") {
                try? MultiCloudCombineBuilder.shared.configureDFYPrimaryVault(result: provisioned)
            }
        }

        // Create mount directory and cache directory
        try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Write .metadata_never_index to keep Spotlight (mdworker) from crawling remote files
        let spotlightBlocker = mountPoint.appendingPathComponent(".metadata_never_index")
        FileManager.default.createFile(atPath: spotlightBlocker.path, contents: nil)

        let meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
        let readChunk = boostVideoBufferEnabled ? "32M" : "8M"
        let readChunkLimit = boostVideoBufferEnabled ? "256M" : "128M"
        let bufferSize = boostVideoBufferEnabled ? "64M" : "32M"

        statusMessage = "Spawning rclone nfsmount daemon..."
        let process = Process()
        process.executableURL = rcloneURL

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env

        // Master rclone nfsmount Flags Table (Section 8.1)
        process.arguments = [
            "nfsmount",
            "ZeroDriveUnified:",
            mountPoint.path,
            "--config=\(MultiCloudCombineBuilder.shared.configPath.path)",
            "--volname=ZeroDrive",
            "--vfs-cache-mode=writes",
            "--cache-dir=\(cacheDir.path)",
            "--vfs-cache-max-size=\(meta.spoolCapGB)G",
            "--vfs-write-back=15s",
            "--vfs-cache-max-age=1m",
            "--vfs-read-chunk-size=\(readChunk)",
            "--vfs-read-chunk-size-limit=\(readChunkLimit)",
            "--buffer-size=\(bufferSize)",
            "--vfs-read-ahead=64M",
            "--dir-cache-time=9999h",
            "--attr-timeout=24h",
            "--allow-non-empty",
            "--noappledouble=true",
            "--noapplexattr=true",
            "--exclude=**/node_modules/**",
            "--exclude=**/target/**",
            "--exclude=**/.venv/**",
            "--exclude=**/.git/objects/pack/**",
            "--exclude=**/.DS_Store",
            "--exclude=.metadata_never_index",
            "--rc",
            "--rc-addr=127.0.0.1:55729",
            "--rc-no-auth"
        ]

        do {
            try process.run()
            self.rcloneProcess = process

            // Poll for JSON-RPC readiness (up to 4.5s)
            var rcReady = false
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if await RcloneRCClient.shared.ping() {
                    rcReady = true
                    break
                }
            }

            self.isMounted = rcReady || process.isRunning
            Self.wasMountedBeforeSleep = self.isMounted
            self.isBusy = false
            self.statusMessage = self.isMounted ? "Mounted at ~/ZeroDrive" : "Mount failed — check credentials"

            // Create Desktop alias for quick Finder access
            createDesktopVolumeAliasIfNeeded()

            // Start telemetry & queue poller + RAM tree pre-warm
            SpoolAndGuardManager.shared.startTelemetryPolling()
            startDaemonHealthWatchdog()
            Task {
                await RAMTreeIndexer.shared.prewarmAll()
            }
        } catch {
            self.statusMessage = "Failed to launch: \(error.localizedDescription)"
            self.isBusy = false
        }
    }

    public func unmountCleanly() async {
        guard isMounted || rcloneProcess != nil else { return }
        isBusy = true
        statusMessage = "Unmounting ~/ZeroDrive..."

        healthMonitorTask?.cancel()
        SpoolAndGuardManager.shared.stopTelemetryPolling()

        await runCommand("/usr/sbin/diskutil", ["unmount", "force", mountPoint.path])
        await runCommand("/sbin/umount", ["-f", mountPoint.path])

        rcloneProcess?.terminate()
        rcloneProcess = nil

        self.isMounted = false
        Self.wasMountedBeforeSleep = false
        self.isBusy = false
        self.statusMessage = "Unmounted"
    }

    public func forceCleanAndRemount() async {
        await unmountCleanly()
        await forceCleanStaleMounts()
        await mountUnifiedDrive()
    }

    public func healDeadMountAfterSleep() async {
        guard isMounted || Self.wasMountedBeforeSleep else { return }
        let isAlive = await RcloneRCClient.shared.ping()
        if !isAlive {
            statusMessage = "Healing NFS mount after system sleep..."
            await forceCleanStaleMounts()
            rcloneProcess?.terminate()
            rcloneProcess = nil
            self.isMounted = false
            await mountUnifiedDrive()
        }
    }

    private func startDaemonHealthWatchdog() {
        healthMonitorTask?.cancel()
        healthMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self = self, self.isMounted, !self.isBusy else { continue }
                if let proc = self.rcloneProcess, !proc.isRunning {
                    self.isMounted = false
                    self.statusMessage = "Daemon stopped unexpectedly — click Force Clean & Remount"
                }
            }
        }
    }

    private func forceCleanStaleMounts() async {
        await runCommand("/usr/sbin/diskutil", ["unmount", "force", mountPoint.path])
        await runCommand("/sbin/umount", ["-f", mountPoint.path])
        await runCommand("/usr/bin/pkill", ["-f", "rclone nfsmount ZeroDriveUnified:"])
    }

    public func resolveRcloneBinary() -> URL? {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "rclone", withExtension: nil),
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("ZeroDrive/bin/rclone"),
            URL(fileURLWithPath: "/Applications/ZeroDrive.app/Contents/Resources/rclone"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zerodrive-build-cache/rclone"),
            URL(fileURLWithPath: "/usr/local/bin/rclone"),
            URL(fileURLWithPath: "/opt/homebrew/bin/rclone")
        ]

        for candidate in candidates.compactMap({ $0 }) {
            if FileManager.default.isExecutableFile(atPath: candidate.path),
               verifySupportsNFSMount(candidate) {
                return candidate
            }
        }
        return nil
    }

    public func resolveOrDownloadRcloneBinary() async -> URL? {
        if let existing = resolveRcloneBinary() {
            return existing
        }
        return await downloadOfficialRcloneEngine()
    }

    /// Auto-downloads the official CGO-enabled universal rclone binary if missing or Homebrew lacks nfsmount
    public func downloadOfficialRcloneEngine() async -> URL? {
        statusMessage = "Downloading official rclone engine..."
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let binDir = appSupport.appendingPathComponent("ZeroDrive/bin")
        let destBin = binDir.appendingPathComponent("rclone")
        let zipPath = binDir.appendingPathComponent("rclone.zip")
        try? FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        #if arch(arm64)
        let rcloneZipURL = "https://downloads.rclone.org/rclone-current-osx-arm64.zip"
        #else
        let rcloneZipURL = "https://downloads.rclone.org/rclone-current-osx-amd64.zip"
        #endif
        let downloadOK = await runCommand(
            "/usr/bin/curl",
            ["-fsSL", rcloneZipURL, "-o", zipPath.path]
        )
        guard downloadOK else { return nil }

        _ = await runCommand("/usr/bin/unzip", ["-q", "-o", zipPath.path, "-d", binDir.path])
        if let subpaths = try? FileManager.default.subpathsOfDirectory(atPath: binDir.path) {
            for rel in subpaths where (rel as NSString).lastPathComponent == "rclone" && rel != "rclone" {
                let extractedURL = binDir.appendingPathComponent(rel)
                try? FileManager.default.removeItem(at: destBin)
                try? FileManager.default.moveItem(at: extractedURL, to: destBin)
                break
            }
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destBin.path)
        try? FileManager.default.removeItem(at: zipPath)

        return verifySupportsNFSMount(destBin) ? destBin : nil
    }

    private func verifySupportsNFSMount(_ binaryURL: URL) -> Bool {
        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = ["nfsmount", "--help"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func createDesktopVolumeAliasIfNeeded() {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/ZeroDrive")
        if !FileManager.default.fileExists(atPath: desktop.path) {
            try? FileManager.default.createSymbolicLink(at: desktop, withDestinationURL: mountPoint)
        }
    }

    @discardableResult
    private func runCommand(_ executable: String, _ arguments: [String]) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: executable)
                task.arguments = arguments
                task.standardOutput = Pipe()
                task.standardError = Pipe()
                do {
                    try task.run()
                    task.waitUntilExit()
                    continuation.resume(returning: task.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
