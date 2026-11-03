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

    /// Opens the given folder in macOS Finder and brings the Finder window to the front
    public func openInFinder(_ url: URL? = nil) {
        let target = url ?? mountPoint.appendingPathComponent("Vault")
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

    /// Automatically pins ~/ZeroDrive right next to Home in Finder's Sidebar Favorites
    public func pinToFinderSidebarIfNeeded() {
        try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sflURL = home.appendingPathComponent("Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.FavoriteItems.sfl4")
        guard let data = try? Data(contentsOf: sflURL),
              var root = (try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data)) as? [String: Any],
              var items = root["items"] as? [[String: Any]] else {
            return
        }

        let alreadyPinned = items.contains { item in
            guard let bm = item["Bookmark"] as? Data else { return false }
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bm, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url.path == mountPoint.path
            }
            return false
        }
        guard !alreadyPinned else { return }

        guard let bm = try? mountPoint.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return
        }
        let newEntry: [String: Any] = [
            "Bookmark": bm,
            "CustomItemProperties": ["com.apple.LSSharedFileList.ItemIsHidden": false] as [String: Any],
            "uuid": UUID().uuidString.uppercased(),
            "visibility": 0
        ]

        var insertIndex = min(5, items.count)
        for (idx, item) in items.enumerated() {
            if let bmData = item["Bookmark"] as? Data {
                var stale = false
                if let u = try? URL(resolvingBookmarkData: bmData, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
                   u.path == home.path {
                    insertIndex = idx + 1
                    break
                }
            }
        }

        items.insert(newEntry, at: insertIndex)
        root["items"] = items
        if let outData = try? NSKeyedArchiver.archivedData(withRootObject: root, requiringSecureCoding: false) {
            try? outData.write(to: sflURL, options: .atomic)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            p.arguments = ["sharedfilelistd"]
            try? p.run()
        }
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

        let vaultDir = mountPoint.appendingPathComponent("Vault").path
        let retakesDir = mountPoint.appendingPathComponent("_Retakes").path

        let workflows: [(bundleName: String, menuTitle: String, iconName: String, shellCommand: String)] = [
            (
                "ZeroDrive - Move to Cloud & Free Space.workflow",
                "ZeroDrive: Move to Cloud & Free Space",
                "NSActionTemplate",
                """
                mkdir -p "\(vaultDir)"
                q=""
                for f in "$@"; do
                  mv -f "$f" "\(vaultDir)/" 2>/dev/null || cp -R "$f" "\(vaultDir)/"
                done
                open -g "zerodrive://finder-action?cmd=refresh" 2>/dev/null || true
                """
            ),
            (
                "ZeroDrive - Copy to Cloud Vault.workflow",
                "ZeroDrive: Copy to 5 TB Cloud Vault",
                "NSActionTemplate",
                """
                mkdir -p "\(vaultDir)"
                for f in "$@"; do
                  cp -R "$f" "\(vaultDir)/"
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
                  mv -f "$f" "\(retakesDir)/"
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
                        <key>NSSendFileTypes</key>
                        <array>
                            <string>public.item</string>
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

        // Refresh macOS dynamic services cache + enable embedded FinderSync extension
        NSUpdateDynamicServices()
        DispatchQueue.global(qos: .utility).async {
            let pbs = Process()
            pbs.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
            pbs.arguments = ["-update"]
            try? pbs.run()

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
