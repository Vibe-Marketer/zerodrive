import Foundation
import AppKit
import CoreServices
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

    public let nfsMountRoot: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".zerodrive-mount")
    }()

    public let mountPoint: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".zerodrive-mount")
    }()

    public let userSymlinkURL: URL = {
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
        let mountPath = home.appendingPathComponent(".zerodrive-mount").path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/umount")
        task.arguments = ["-f", mountPath]
        try? task.run()
        task.waitUntilExit()
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

        // Fast-path: if the NFS daemon and kernel mount are already live, adopt them without unmounting
        var mountRoot = nfsMountRoot
        mountRoot.removeAllCachedResourceValues()
        if ((try? mountRoot.resourceValues(forKeys: [.isVolumeKey]).isVolume) ?? false),
           isPortListening(55730),
           await RcloneRCClient.shared.ping() {
            self.isMounted = true
            Self.wasMountedBeforeSleep = true
            self.isBusy = false
            self.statusMessage = "Mounted at ~/ZeroDrive"
            ensureUserSymlink()
            SpoolAndGuardManager.shared.startTelemetryPolling()
            startDaemonHealthWatchdog()
            return
        }

        statusMessage = "Cleaning stale NFS mounts..."

        // [Mandatory Step 1] Force clean any dead/ghost NFS mounts
        await forceCleanStaleMounts()

        statusMessage = "Locating & verifying rclone nfsmount engine..."
        guard let rcloneURL = await resolveOrDownloadRcloneBinary() else {
            statusMessage = "rclone engine missing — click Download Official Engine"
            isBusy = false
            return
        }

        // Ensure [ZeroDriveUnified] exists in ~/.config/rclone/rclone.conf and uses union at root with any connected clouds
        if !MultiCloudCombineBuilder.shared.hasConfiguredPrimaryVault() {
            if let provisioned = try? await DFYProvisioningClient.shared.provisionVault(email: "trial@zerodrive.aisimple.co", licenseKey: "TRIAL") {
                try? MultiCloudCombineBuilder.shared.configureDFYPrimaryVault(result: provisioned)
            }
        }
        MultiCloudCombineBuilder.shared.ensureUnifiedUnionConfig()

        // Create hidden NFS mount directory and cache directory
        try? FileManager.default.createDirectory(at: nfsMountRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        ensureUserSymlink()

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

        // Master rclone serve nfs + mount_nfs -o nolocks,nobrowse on ~/.zerodrive-mount so ~/.zerodrive-mount/ZeroDrive has isVolume=false (no Eject button in Finder!)
        let nfsPort = 55730
        let defaultTimeStr = ISO8601DateFormatter().string(from: Date())
        let minFreeGB = max(5, meta.minFreeSpaceGB)
        process.arguments = [
            "serve",
            "nfs",
            "ZeroDriveUnified:",
            "--config=\(MultiCloudCombineBuilder.shared.configPath.path)",
            "--addr=127.0.0.1:\(nfsPort)",
            "--default-time=\(defaultTimeStr)",
            "--vfs-cache-mode=full",
            "--cache-dir=\(cacheDir.path)",
            "--vfs-cache-max-size=\(meta.spoolCapGB)G",
            "--vfs-cache-min-free-space=\(minFreeGB)G",
            "--vfs-write-back=15s",
            "--vfs-cache-max-age=24h",
            "--vfs-read-chunk-size=16M",
            "--vfs-read-chunk-size-limit=512M",
            "--buffer-size=64M",
            "--vfs-read-ahead=128M",
            "--dir-cache-time=24h",
            "--vfs-fast-fingerprint",
            "--transfers=16",
            "--s3-upload-cutoff=32M",
            "--s3-chunk-size=16M",
            "--s3-upload-concurrency=4",
            "--exclude=**/.DS_Store",
            "--exclude=**/.DS_Store.rclonelink",
            "--exclude=**/._*",
            "--exclude=**/.Spotlight-V100/**",
            "--exclude=**/.fseventsd/**",
            "--exclude=**/.Trashes/**",
            "--exclude=**/.TemporaryItems/**",
            "--vfs-links",
            "--rc",
            "--rc-addr=127.0.0.1:55729",
            "--rc-no-auth"
        ]

        do {
            try process.run()
            self.rcloneProcess = process

            // Poll for both JSON-RPC (55729) and NFS server (55730) readiness
            var nfsReady = false
            for _ in 0..<90 {
                if isPortListening(nfsPort) {
                    let pingOk = await RcloneRCClient.shared.ping()
                    if pingOk {
                        nfsReady = true
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            if nfsReady {
                let nfsMountOptions = "port=\(nfsPort),mountport=\(nfsPort),nolocks,nobrowse,vers=3,tcp,rsize=65536,wsize=65536,readahead=128,actimeo=60,noatime,noacl,async"
                await runCommand("/sbin/mount_nfs", [
                    "-o", nfsMountOptions,
                    "localhost:/",
                    nfsMountRoot.path
                ])
            }

            self.isMounted = nfsReady && process.isRunning
            Self.wasMountedBeforeSleep = self.isMounted
            self.isBusy = false
            self.statusMessage = self.isMounted ? "Mounted at ~/ZeroDrive" : "Mount failed — check credentials"

            // Ensure ~/ZeroDrive symlink & Desktop alias & non-ejectable Finder Sidebar folder entry
            ensureUserSymlink()
            ensureMetadataNeverIndex()
            createDesktopVolumeAliasIfNeeded()
            if self.isMounted {
                pinToFinderSidebarIfNeeded()
            }

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

        // 1. Forcibly unmount kernel NFS filesystem FIRST so the OS kernel releases before the server daemon stops
        await runCommand("/sbin/umount", ["-f", nfsMountRoot.path])

        // 2. Terminate the rclone process only after the kernel mount is cleanly dismantled
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

    /// Opens the given folder in macOS Finder and brings the Finder window to the front
    public func openInFinder(_ url: URL? = nil) {
        let target = url ?? mountPoint
        let folderToOpen = FileManager.default.fileExists(atPath: target.path) ? target : mountPoint
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [folderToOpen.path]
        try? proc.run()
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
                if !self.isPortListening(55730) {
                    self.isMounted = false
                    self.statusMessage = "Reconnecting drive…"
                    await self.mountUnifiedDrive()
                    continue
                }
                // Verify the kernel NFS mount is still attached; if detached while rclone is alive, re-attach immediately
                var mountRoot = self.nfsMountRoot
                mountRoot.removeAllCachedResourceValues()
                let isVol = (try? mountRoot.resourceValues(forKeys: [.isVolumeKey]).isVolume) ?? false
                if !isVol {
                    let watchdogMountOpts = "port=55730,mountport=55730,nolocks,nobrowse,vers=3,tcp,rsize=65536,wsize=65536,readahead=128,actimeo=60,noatime,noacl,async"
                    await self.runCommand("/sbin/mount_nfs", [
                        "-o", watchdogMountOpts,
                        "localhost:/",
                        self.nfsMountRoot.path
                    ])
                    self.ensureMetadataNeverIndex()
                }
            }
        }
    }

    private func forceCleanStaleMounts() async {
        for path in [nfsMountRoot.path, userSymlinkURL.path] {
            await runCommand("/sbin/umount", ["-f", path])
        }
        await runCommand("/usr/bin/pkill", ["-f", "rclone nfsmount ZeroDriveUnified:"])
        await runCommand("/usr/bin/pkill", ["-f", "rclone serve nfs ZeroDriveUnified:"])
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

    private func ensureUserSymlink() {
        let fm = FileManager.default
        if let dest = try? fm.destinationOfSymbolicLink(atPath: userSymlinkURL.path), dest == mountPoint.path {
            return
        }
        // Replace ~/ZeroDrive if it is an empty leftover mount directory or broken symlink
        if let attrs = try? fm.attributesOfItem(atPath: userSymlinkURL.path),
           attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            try? fm.removeItem(at: userSymlinkURL)
        } else if fm.fileExists(atPath: userSymlinkURL.path) {
            let legacySubdir = userSymlinkURL.appendingPathComponent("ZeroDrive")
            if let subContents = try? fm.contentsOfDirectory(atPath: legacySubdir.path), subContents.isEmpty {
                try? fm.removeItem(at: legacySubdir)
            }
            if let contents = try? fm.contentsOfDirectory(atPath: userSymlinkURL.path), contents.isEmpty {
                try? fm.removeItem(at: userSymlinkURL)
            }
        }
        if !fm.fileExists(atPath: userSymlinkURL.path) {
            try? fm.createSymbolicLink(at: userSymlinkURL, withDestinationURL: mountPoint)
        }
    }

    public func ensureMetadataNeverIndex() {
        let fm = FileManager.default
        let targets = [
            nfsMountRoot.appendingPathComponent(".metadata_never_index"),
            nfsMountRoot.appendingPathComponent("My Drive/.metadata_never_index")
        ]
        for target in targets {
            if !fm.fileExists(atPath: target.path) {
                try? "".write(to: target, atomically: true, encoding: .utf8)
            }
        }
    }

    private func createDesktopVolumeAliasIfNeeded() {
        let fm = FileManager.default
        let desktopDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        // Remove any iCloud conflict duplicates like "ZeroDrive 2", "ZeroDrive 3"
        if let items = try? fm.contentsOfDirectory(atPath: desktopDir.path) {
            for item in items where item.hasPrefix("ZeroDrive ") {
                let dupURL = desktopDir.appendingPathComponent(item)
                if let attrs = try? fm.attributesOfItem(atPath: dupURL.path),
                   attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                    try? fm.removeItem(at: dupURL)
                }
            }
        }
        let desktop = desktopDir.appendingPathComponent("ZeroDrive")
        if let dest = try? fm.destinationOfSymbolicLink(atPath: desktop.path), dest == mountPoint.path {
            return
        }
        if let attrs = try? fm.attributesOfItem(atPath: desktop.path),
           attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            try? fm.removeItem(at: desktop)
        }
        if !fm.fileExists(atPath: desktop.path) {
            try? fm.createSymbolicLink(at: desktop, withDestinationURL: mountPoint)
        }
    }

    /// Pins ~/.zerodrive-mount/My Drive (isVolume = false, so no Eject icon) into Finder's Sidebar Favorites via LaunchServices XPC
    public func pinToFinderSidebarIfNeeded() {
        let myDriveURL = mountPoint.appendingPathComponent("My Drive")
        let targetURL = FileManager.default.fileExists(atPath: myDriveURL.path) ? myDriveURL : userSymlinkURL

        guard let list = LSSharedFileListCreate(
            nil,
            kLSSharedFileListFavoriteItems.takeUnretainedValue(),
            nil
        )?.takeRetainedValue(),
        let snapshot = LSSharedFileListCopySnapshot(list, nil)?.takeRetainedValue() as? [LSSharedFileListItem],
        let firstItem = snapshot.first else {
            return
        }

        // Remove any stale ZeroDrive / .zerodrive-mount entries first so re-clicking "Add to Sidebar" refreshes cleanly
        for item in snapshot {
            if let existingURL = LSSharedFileListItemCopyResolvedURL(
                item,
                LSSharedFileListResolutionFlags(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes),
                nil
            )?.takeRetainedValue() as URL? {
                if existingURL.path == targetURL.path ||
                   existingURL.path == mountPoint.path ||
                   existingURL.path == userSymlinkURL.path ||
                   existingURL.path.hasPrefix(mountPoint.path + "/") {
                    LSSharedFileListItemRemove(list, item)
                }
            }
        }

        let refreshedSnapshot = (LSSharedFileListCopySnapshot(list, nil)?.takeRetainedValue() as? [LSSharedFileListItem]) ?? snapshot
        let afterItem = refreshedSnapshot.count > 2 ? refreshedSnapshot[2] : (refreshedSnapshot.first ?? firstItem)

        _ = LSSharedFileListInsertItemURL(
            list,
            afterItem,
            "My Drive" as CFString,
            nil,
            targetURL as CFURL,
            nil,
            nil
        )
    }

    /// Installs real macOS Automator .workflow Quick Actions into ~/Library/Services/ and enables the embedded FinderSync extension
    public func installFinderWorkflowsAndEnableExtension() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let servicesDir = home.appendingPathComponent("Library/Services")
        try? FileManager.default.createDirectory(at: servicesDir, withIntermediateDirectories: true)

        // Remove legacy .sh files if present
        for oldSh in [
            "ZeroDrive - Move to _Retakes.sh",
            "ZeroDrive - Evict Local Spool Copy.sh",
            "ZeroDrive - Refresh Cloud Folder.sh"
        ] {
            try? FileManager.default.removeItem(at: servicesDir.appendingPathComponent(oldSh))
        }

        let driveDir = mountPoint.appendingPathComponent("My Drive").path
        let retakesDir = mountPoint.appendingPathComponent("My Drive/_Retakes").path

        let rcloneBin = resolveRcloneBinary()?.path ?? "/Applications/ZeroDrive.app/Contents/Resources/rclone"
        let rcloneConf = MultiCloudCombineBuilder.shared.configPath.path
        let meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
        let remoteDst = "primary_vault:\(meta.bucketAndPrefix)"

        let workflows: [(bundleName: String, menuTitle: String, iconName: String, shellCommand: String)] = [
            (
                "ZeroDrive - Move to Cloud & Free Space.workflow",
                "ZeroDrive: Move to ZeroDrive & Free Mac Space",
                "NSActionTemplate",
                """
                for f in "$@"; do
                  /usr/bin/python3 /Users/Naegele/_LAB/zerodrive/turbo-migrate-dashboard.py "$f"
                done
                open -g "zerodrive://finder-action?cmd=refresh" 2>/dev/null || true
                """
            ),
            (
                "ZeroDrive - Copy to Cloud Vault.workflow",
                "ZeroDrive: Copy to ZeroDrive (Keep on Mac)",
                "NSActionTemplate",
                """
                for f in "$@"; do
                  name="$(basename "$f")"
                  "\(rcloneBin)" copy "$f" "\(remoteDst)/$name" --config="\(rcloneConf)" --s3-upload-cutoff=32M --s3-chunk-size=16M --s3-upload-concurrency=4 --timeout=60s
                done
                open -g "zerodrive://finder-action?cmd=refresh" 2>/dev/null || true
                """
            ),
            (
                "ZeroDrive - Move to _Retakes.workflow",
                "ZeroDrive: Move to _Retakes Folder",
                "NSActionTemplate",
                """
                mkdir -p "\(retakesDir)"
                for f in "$@"; do
                  name="$(basename "$f")"
                  if cp -R -X "$f" "\(retakesDir)/$name" 2>/dev/null; then
                    rm -rf "$f"
                  fi
                done
                """
            ),
            (
                "ZeroDrive - Free Local Cache Copy.workflow",
                "ZeroDrive: Free Local Cache Copy",
                "NSActionTemplate",
                """
                for f in "$@"; do
                  rel="${f#\(mountPoint.path)/}"
                  curl -s -X POST http://127.0.0.1:55729/vfs/forget -H "Content-Type: application/json" -d "{\\"file\\": \\"$rel\\"}" >/dev/null 2>&1 || true
                done
                """
            )
        ]

        for wf in workflows {
            let wfDir = servicesDir.appendingPathComponent(wf.bundleName).appendingPathComponent("Contents")
            try? FileManager.default.createDirectory(at: wfDir, withIntermediateDirectories: true)

            let infoPlist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>NSServices</key>
                <array>
                    <dict>
                        <key>NSBackgroundColorName</key>
                        <string>background</string>
                        <key>NSIconName</key>
                        <string>\(wf.iconName)</string>
                        <key>NSMenuItem</key>
                        <dict>
                            <key>default</key>
                            <string>\(wf.menuTitle)</string>
                        </dict>
                        <key>NSMessage</key>
                        <string>runWorkflowAsService</string>
                        <key>NSRequiredContext</key>
                        <dict>
                            <key>NSApplicationIdentifier</key>
                            <string>com.apple.finder</string>
                        </dict>
                        <key>NSSendTypes</key>
                        <array>
                            <string>NSFilenamesPboardType</string>
                            <string>public.file-url</string>
                        </array>
                        <key>NSSendFileTypes</key>
                        <array>
                            <string>public.item</string>
                            <string>public.folder</string>
                            <string>public.directory</string>
                            <string>public.data</string>
                        </array>
                    </dict>
                </array>
            </dict>
            </plist>
            """

            let escapedCmd = wf.shellCommand
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")

            let wflow = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>AMApplicationBuild</key>
                <string>534</string>
                <key>AMApplicationVersion</key>
                <string>2.10</string>
                <key>AMDocumentVersion</key>
                <string>2</string>
                <key>actions</key>
                <array>
                    <dict>
                        <key>action</key>
                        <dict>
                            <key>AMAccepts</key>
                            <dict>
                                <key>Container</key>
                                <string>List</string>
                                <key>Optional</key>
                                <true/>
                                <key>Types</key>
                                <array>
                                    <string>com.apple.cocoa.string</string>
                                </array>
                            </dict>
                            <key>AMActionVersion</key>
                            <string>2.0.3</string>
                            <key>AMApplication</key>
                            <array>
                                <string>Automator</string>
                            </array>
                            <key>AMParameterProperties</key>
                            <dict>
                                <key>COMMAND_STRING</key>
                                <dict/>
                                <key>CheckedForUserDefaultShell</key>
                                <dict/>
                                <key>inputMethod</key>
                                <dict/>
                                <key>shell</key>
                                <dict/>
                                <key>source</key>
                                <dict/>
                            </dict>
                            <key>AMProvides</key>
                            <dict>
                                <key>Container</key>
                                <string>List</string>
                                <key>Types</key>
                                <array>
                                    <string>com.apple.cocoa.string</string>
                                </array>
                            </dict>
                            <key>ActionBundlePath</key>
                            <string>/System/Library/Automator/Run Shell Script.action</string>
                            <key>ActionName</key>
                            <string>Run Shell Script</string>
                            <key>ActionParameters</key>
                            <dict>
                                <key>COMMAND_STRING</key>
                                <string>\(escapedCmd)</string>
                                <key>CheckedForUserDefaultShell</key>
                                <true/>
                                <key>inputMethod</key>
                                <integer>1</integer>
                                <key>shell</key>
                                <string>/bin/zsh</string>
                                <key>source</key>
                                <string></string>
                            </dict>
                            <key>BundleIdentifier</key>
                            <string>com.apple.RunShellScript</string>
                            <key>CFBundleVersion</key>
                            <string>2.0.3</string>
                            <key>CanShowSelectedItemsWhenRun</key>
                            <false/>
                            <key>CanShowWhenRun</key>
                            <true/>
                            <key>Category</key>
                            <array>
                                <string>AMCategoryUtilities</string>
                            </array>
                            <key>Class Name</key>
                            <string>RunShellScriptAction</string>
                            <key>InputUUID</key>
                            <string>\(UUID().uuidString.uppercased())</string>
                            <key>OutputUUID</key>
                            <string>\(UUID().uuidString.uppercased())</string>
                            <key>UUID</key>
                            <string>\(UUID().uuidString.uppercased())</string>
                            <key>UnlocalizedApplications</key>
                            <array>
                                <string>Automator</string>
                            </array>
                        </dict>
                        <key>isViewVisible</key>
                        <integer>1</integer>
                    </dict>
                </array>
                <key>connectors</key>
                <dict/>
                <key>workflowMetaData</key>
                <dict>
                    <key>applicationBundleIDsByPath</key>
                    <dict/>
                    <key>applicationPaths</key>
                    <array/>
                    <key>inputTypeIdentifier</key>
                    <string>com.apple.Automator.fileSystemObject</string>
                    <key>outputTypeIdentifier</key>
                    <string>com.apple.Automator.nothing</string>
                    <key>presentationMode</key>
                    <integer>15</integer>
                    <key>processesInput</key>
                    <false/>
                    <key>serviceInputTypeIdentifier</key>
                    <string>com.apple.Automator.fileSystemObject</string>
                    <key>serviceOutputTypeIdentifier</key>
                    <string>com.apple.Automator.nothing</string>
                    <key>serviceProcessesInput</key>
                    <false/>
                    <key>systemImageName</key>
                    <string>\(wf.iconName)</string>
                    <key>useAutomaticInputType</key>
                    <false/>
                    <key>workflowTypeIdentifier</key>
                    <string>com.apple.Automator.servicesMenu</string>
                </dict>
            </dict>
            </plist>
            """

            try? infoPlist.write(to: wfDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
            try? wflow.write(to: wfDir.appendingPathComponent("document.wflow"), atomically: true, encoding: .utf8)
        }

        // Enable all ZeroDrive services in ~/Library/Preferences/pbs.plist (NSServicesStatus) so they appear on folders & files in Services / Quick Actions
        let pbsPlistURL = home.appendingPathComponent("Library/Preferences/pbs.plist")
        var pbsRoot = (NSDictionary(contentsOf: pbsPlistURL) as? [String: Any]) ?? [:]
        var servicesStatus = (pbsRoot["NSServicesStatus"] as? [String: Any]) ?? [:]
        let enabledEntry: [String: Any] = [
            "enabled_context_menu": true,
            "enabled_services_menu": true,
            "presentation_modes": [
                "ContextMenu": true,
                "ServicesMenu": true,
                "QuickActions": true
            ]
        ]
        let serviceKeys = [
            "co.aisimple.zerodrive - ZeroDrive: Move to ZeroDrive & Free Mac Space - moveToZeroDriveService",
            "co.aisimple.zerodrive - ZeroDrive: Copy to ZeroDrive (Keep on Mac) - copyToZeroDriveService",
            "co.aisimple.zerodrive - ZeroDrive: Move to _Retakes Folder - moveToRetakesService",
            "(null) - ZeroDrive: Move to ZeroDrive & Free Mac Space - runWorkflowAsService",
            "(null) - ZeroDrive: Copy to ZeroDrive (Keep on Mac) - runWorkflowAsService",
            "(null) - ZeroDrive: Move to _Retakes Folder - runWorkflowAsService",
            "(null) - ZeroDrive: Free Local Cache Copy - runWorkflowAsService"
        ]
        for key in serviceKeys {
            servicesStatus[key] = enabledEntry
        }
        pbsRoot["NSServicesStatus"] = servicesStatus
        (pbsRoot as NSDictionary).write(to: pbsPlistURL, atomically: true)

        // Refresh macOS dynamic services cache + enable embedded FinderSync extension
        NSUpdateDynamicServices()
        DispatchQueue.global(qos: .utility).async {
            for arg in ["-flush", "-update"] {
                let pbs = Process()
                pbs.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
                pbs.arguments = [arg]
                try? pbs.run()
                pbs.waitUntilExit()
            }

            if let plugInsURL = Bundle.main.builtInPlugInsURL {
                let appexPath = plugInsURL.appendingPathComponent("ZeroDriveFinderSync.appex").path
                if FileManager.default.fileExists(atPath: appexPath) {
                    let pk1 = Process()
                    pk1.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
                    pk1.arguments = ["-a", appexPath]
                    try? pk1.run()
                    pk1.waitUntilExit()

                    let pk2 = Process()
                    pk2.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
                    pk2.arguments = ["-e", "use", "-i", "co.aisimple.zerodrive.FinderSync"]
                    try? pk2.run()
                }
            }
        }
    }

    private func isPortListening(_ port: Int) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        let res = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if res == 0 { return true }
        if errno == EINPROGRESS {
            var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
            let pollRes = poll(&pfd, 1, 150)
            if pollRes > 0 && (pfd.revents & Int16(POLLOUT)) != 0 {
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &len)
                return err == 0
            }
        }
        return false
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
