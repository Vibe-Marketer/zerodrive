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
        // Loopback lo0 (127.0.0.1) stays alive in kernel across sleep!
        // NEVER run `umount -f` before sleep — force-unmounting rips open folders away from Claude Code / Finder
        // and triggers macOS's "Server connections interrupted" warning popup!
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
        return home.appendingPathComponent(".zerodrive")
    }()

    public let mountPoint: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".zerodrive")
    }()

    public let userSymlinkURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("ZeroDrive")
    }()

    public let cacheDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Caches/ZeroDrive")
    }()

    private var rcloneProcess: Process?
    private var healthMonitorTask: Task<Void, Never>?
    private var consecutiveHealthFailures: Int = 0
    private var lastRemoteDirRefresh: [String: Date] = [:]
    private var pendingRemoteDirTasks: [String: Task<Void, Never>] = [:]

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

    public func autoMountIfConfigured() async {
        guard MultiCloudCombineBuilder.shared.hasConfiguredPrimaryVault(),
              ManageLicensing.shared.isLicensed else {
            statusMessage = "Sign In Required"
            return
        }
        await mountUnifiedDrive()
    }

    private func buildRcloneServeArguments() -> [String] {
        let meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
        let readChunk = boostVideoBufferEnabled ? "32M" : "16M"
        let readChunkLimit = boostVideoBufferEnabled ? "512M" : "256M"
        let bufferSize = boostVideoBufferEnabled ? "64M" : "32M"
        let nfsPort = 55730
        let defaultTimeStr = ISO8601DateFormatter().string(from: Date())
        let minFreeGB = max(5, meta.minFreeSpaceGB)
        let nfsHandleCacheDir = cacheDir.appendingPathComponent("nfs-handles")
        try? FileManager.default.createDirectory(at: nfsHandleCacheDir, withIntermediateDirectories: true)

        return [
            "serve",
            "nfs",
            "ZeroDriveUnified:",
            "--config=\(MultiCloudCombineBuilder.shared.configPath.path)",
            "--addr=127.0.0.1:\(nfsPort)",
            "--default-time=\(defaultTimeStr)",
            "--nfs-cache-type=disk",
            "--nfs-cache-dir=\(nfsHandleCacheDir.path)",
            "--nfs-cache-handle-limit=1000000",
            "--vfs-cache-mode=full",
            "--cache-dir=\(cacheDir.path)",
            "--vfs-cache-max-size=\(meta.spoolCapGB)G",
            "--vfs-cache-min-free-space=\(minFreeGB)G",
            "--vfs-write-back=5s",
            "--vfs-cache-max-age=168h",
            "--vfs-read-chunk-size=\(readChunk)",
            "--vfs-read-chunk-size-limit=\(readChunkLimit)",
            "--buffer-size=\(bufferSize)",
            "--dir-cache-time=1h",
            "--vfs-fast-fingerprint",
            "--use-server-modtime",
            "--disable-http2",
            "--s3-disable-http2",
            "--transfers=4",
            "--s3-upload-cutoff=32M",
            "--s3-chunk-size=8M",
            "--s3-upload-concurrency=2",
            "--retries=5",
            "--low-level-retries=10",
            "--retries-sleep=1s",
            "--timeout=20s",
            "--contimeout=10s",
            "--exclude=**/.DS_Store",
            "--exclude=**/.DS_Store.rclonelink",
            "--exclude=**/._*",
            "--exclude=**/.nfs*",
            "--exclude=**/.Spotlight-V100/**",
            "--exclude=**/.fseventsd/**",
            "--exclude=**/.Trashes/**",
            "--exclude=**/.TemporaryItems/**",
            "--vfs-links",
            "--rc",
            "--rc-addr=127.0.0.1:55729",
            "--rc-no-auth"
        ]
    }

    private func spawnRcloneServeProcess(rcloneURL: URL) throws -> Process {
        let process = Process()
        process.executableURL = rcloneURL
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        process.arguments = buildRcloneServeArguments()

        let logFileURL = cacheDir.appendingPathComponent("rclone-daemon.log")
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
            fileHandle.seekToEndOfFile()
            process.standardOutput = fileHandle
            process.standardError = fileHandle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self = self else { return }
                if self.rcloneProcess === proc && self.isMounted && !self.isBusy {
                    NSLog("[ZeroDrive] rclone daemon exited unexpectedly (code %d) — attempting hitless TCP recovery without unmount...", proc.terminationStatus)
                    let recovered = await self.respawnDaemonHitlessly()
                    if !recovered {
                        self.isMounted = false
                        self.statusMessage = "Reconnecting drive…"
                        await self.mountUnifiedDrive()
                    }
                }
            }
        }
        try process.run()
        self.rcloneProcess = process
        return process
    }

    private func waitForRcloneDaemonReady(nfsPort: Int = 55730, maxPolls: Int = 90) async -> Bool {
        for _ in 0..<maxPolls {
            if isPortListening(nfsPort) {
                if await RcloneRCClient.shared.ping() {
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return false
    }

    /// Restarts ONLY the `rclone serve nfs` process on 127.0.0.1:55730 with persistent disk file handles
    /// WITHOUT running `umount -f`, so Finder and open Claude Code terminals never lose their connection!
    @discardableResult
    public func respawnDaemonHitlessly() async -> Bool {
        guard !isBusy else { return false }
        guard await isKernelNFSMounted() else { return false }
        guard let rcloneURL = await resolveOrDownloadRcloneBinary() else { return false }

        isBusy = true
        defer { isBusy = false }

        cleanPoisonedCacheEntries()
        MultiCloudCombineBuilder.shared.ensureUnifiedUnionConfig()

        // Ensure port 55730 is free before binding replacement daemon (never touch umount!)
        rcloneProcess?.terminate()
        rcloneProcess = nil
        if isPortListening(55730) {
            await runCommand("/usr/bin/pkill", ["-f", "rclone serve nfs ZeroDriveUnified:"])
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        do {
            let proc = try spawnRcloneServeProcess(rcloneURL: rcloneURL)
            let ready = await waitForRcloneDaemonReady(nfsPort: 55730, maxPolls: 45)
            let live = (ready && proc.isRunning) ? (await probeMountLiveness(timeoutSeconds: 6.0)) : false
            if live {
                self.isMounted = true
                Self.wasMountedBeforeSleep = true
                self.consecutiveHealthFailures = 0
                self.statusMessage = "Mounted at ~/ZeroDrive"
                ensureUserSymlink()
                SpoolAndGuardManager.shared.startTelemetryPolling()
                startDaemonHealthWatchdog()
                NSLog("[ZeroDrive] Hitless NFS daemon recovery succeeded on 127.0.0.1:55730 (0 unmounts)")
                return true
            }
        } catch {
            NSLog("[ZeroDrive] Hitless daemon spawn error: %@", error.localizedDescription)
        }
        return false
    }

    public func mountUnifiedDrive() async {
        guard !isMounted, !isBusy else { return }
        isBusy = true

        // Fast-path 1: if both daemon (55730) and kernel NFS mount are already live, adopt them with zero disruption
        if isPortListening(55730),
           await RcloneRCClient.shared.ping(),
           await probeMountLiveness(timeoutSeconds: 5.0) {
            self.isMounted = true
            Self.wasMountedBeforeSleep = true
            self.consecutiveHealthFailures = 0
            self.isBusy = false
            self.statusMessage = "Mounted at ~/ZeroDrive"
            ensureUserSymlink()
            SpoolAndGuardManager.shared.startTelemetryPolling()
            startDaemonHealthWatchdog()
            return
        }

        // Fast-path 2: if ~/.zerodrive is STILL mounted in the kernel (e.g., daemon restarted), revive port 55730 hitlessly WITHOUT umount -f!
        if await isKernelNFSMounted() {
            self.isBusy = false
            if await respawnDaemonHitlessly() {
                return
            }
            self.isBusy = true
        }

        statusMessage = "Cleaning stale NFS mounts..."

        // Only run forceCleanStaleMounts when starting from an unmounted or irrecoverable state
        await forceCleanStaleMounts()
        cleanPoisonedCacheEntries()

        statusMessage = "Locating & verifying ZeroDrive streaming engine..."
        guard let rcloneURL = await resolveOrDownloadRcloneBinary() else {
            statusMessage = "Streaming engine missing — click Download Engine"
            isBusy = false
            return
        }

        if !MultiCloudCombineBuilder.shared.hasConfiguredPrimaryVault() {
            if let provisioned = try? await DFYProvisioningClient.shared.provisionVault(email: "trial@zerodrive.aisimple.co", licenseKey: "TRIAL") {
                try? MultiCloudCombineBuilder.shared.configureDFYPrimaryVault(result: provisioned)
            }
        }
        MultiCloudCombineBuilder.shared.ensureUnifiedUnionConfig()

        try? FileManager.default.createDirectory(at: nfsMountRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        ensureUserSymlink()

        statusMessage = "Starting ZeroDrive streaming daemon..."
        let nfsPort = 55730

        do {
            let process = try spawnRcloneServeProcess(rcloneURL: rcloneURL)
            let nfsReady = await waitForRcloneDaemonReady(nfsPort: nfsPort, maxPolls: 90)

            if nfsReady {
                // locallocks = real kernel flock/fcntl for Claude Code, Codex, git & SQLite
                // nfc = automatic Unicode NFC filename normalization in kernel
                // timeo=600 + mutejukebox + deadtimeout=0 = tolerant of slow cold cloud operations without disconnect popups
                // 127.0.0.1:/ = pure IPv4 loopback so macOS never adds ::1 to the NFS server location list
                let nfsMountOptions = "port=\(nfsPort),mountport=\(nfsPort),locallocks,nobrowse,nfc,vers=3,tcp,rsize=65536,wsize=65536,readahead=128,acregmin=2,acregmax=15,acdirmin=1,acdirmax=2,nonegnamecache,noatime,noacl,intr,timeo=600,retrans=5,mutejukebox,deadtimeout=0"
                let mountedOk = await runCommandBounded("/sbin/mount_nfs", [
                    "-o", nfsMountOptions,
                    "127.0.0.1:/",
                    nfsMountRoot.path
                ], timeoutSeconds: 8.0)
                if !mountedOk {
                    let alreadyMounted = await isKernelNFSMounted()
                    if !alreadyMounted {
                        // Self-heal EBUSY if an orphaned kernel dounmount holds the previous ~/.zerodrive directory inode
                        rotateWedgedMountDirectoryInode()
                        _ = await runCommandBounded("/sbin/mount_nfs", [
                            "-o", nfsMountOptions,
                            "127.0.0.1:/",
                            nfsMountRoot.path
                        ], timeoutSeconds: 8.0)
                    }
                }
            }

            let mountLive: Bool
            if nfsReady && process.isRunning {
                mountLive = await probeMountLiveness(timeoutSeconds: 6.0)
            } else {
                mountLive = false
            }
            self.isMounted = mountLive
            Self.wasMountedBeforeSleep = self.isMounted
            self.consecutiveHealthFailures = 0
            self.isBusy = false
            self.statusMessage = self.isMounted ? "Mounted at ~/ZeroDrive" : "Mount failed — check credentials"

            ensureUserSymlink()
            createDesktopVolumeAliasIfNeeded()
            if self.isMounted {
                ensureMetadataNeverIndex()
                pinToFinderSidebarIfNeeded()
            }

            SpoolAndGuardManager.shared.startTelemetryPolling()
            startDaemonHealthWatchdog()
            Task.detached(priority: .utility) {
                await RAMTreeIndexer.shared.prewarmAll()
                await ManageGlobalSearch.shared.loadCacheFromDisk()
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

        // 1. Unmount kernel NFS filesystem FIRST while rclone is still alive so pending RPCs flush in <0.1s
        if await isKernelNFSMounted() {
            let cleanOk = await runCommandBounded("/sbin/umount", [nfsMountRoot.path], timeoutSeconds: 3.0)
            if !cleanOk {
                _ = await runCommandBounded("/sbin/umount", ["-f", nfsMountRoot.path], timeoutSeconds: 4.0)
            }
        }

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
        let target = url ?? userSymlinkURL
        NSWorkspace.shared.open(target)
    }

    public func healDeadMountAfterSleep() async {
        guard isMounted || Self.wasMountedBeforeSleep else { return }
        // Give user-space sockets 1.2s to thaw cleanly on wake
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        let portOk = isPortListening(55730)
        let pingOk = portOk ? (await RcloneRCClient.shared.ping()) : false
        let mountOk = pingOk ? (await probeMountLiveness(timeoutSeconds: 6.0)) : false

        if pingOk && mountOk {
            // Mount survived sleep seamlessly — refresh live SSE push socket for fresh Wi-Fi without touching mount!
            Task.detached(priority: .utility) {
                await ManageFileProvider.shared.restartEventStreamAfterWake()
            }
            return
        }

        // Attempt hitless TCP daemon respawn first so open terminals/Finder never see a disconnect!
        if await respawnDaemonHitlessly() {
            Task.detached(priority: .utility) {
                await ManageFileProvider.shared.restartEventStreamAfterWake()
            }
            return
        }

        statusMessage = "Reconnecting drive after sleep..."
        await forceCleanStaleMounts()
        rcloneProcess?.terminate()
        rcloneProcess = nil
        self.isMounted = false
        await mountUnifiedDrive()
        Task.detached(priority: .utility) {
            await ManageFileProvider.shared.restartEventStreamAfterWake()
        }
    }

    public func refreshVFSForRemoteChange(paths: [String]) async {
        guard isMounted, !isBusy else { return }
        let now = Date()
        var immediateDirs: [String] = []
        var trailingDirs: [String] = []
        for raw in paths {
            var clean = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            if clean.hasPrefix("My Drive/") {
                clean = String(clean.dropFirst("My Drive/".count))
            } else if clean == "My Drive" {
                clean = ""
            }
            let vfsDir: String
            if let lastSlash = clean.lastIndex(of: "/") {
                let parent = String(clean[..<lastSlash])
                vfsDir = parent.isEmpty ? "My Drive" : "My Drive/\(parent)"
            } else {
                vfsDir = "My Drive"
            }
            if let last = lastRemoteDirRefresh[vfsDir], now.timeIntervalSince(last) < 1.2 {
                if !trailingDirs.contains(vfsDir) {
                    trailingDirs.append(vfsDir)
                }
                continue
            }
            lastRemoteDirRefresh[vfsDir] = now
            if !immediateDirs.contains(vfsDir) {
                immediateDirs.append(vfsDir)
            }
        }
        if !immediateDirs.isEmpty {
            Task.detached(priority: .utility) {
                for dir in immediateDirs {
                    _ = await RcloneRCClient.shared.refreshVFSTree(dir: dir, recursive: false)
                }
            }
        }
        for dir in trailingDirs {
            pendingRemoteDirTasks[dir]?.cancel()
            pendingRemoteDirTasks[dir] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.lastRemoteDirRefresh[dir] = Date()
                    self?.pendingRemoteDirTasks.removeValue(forKey: dir)
                }
                _ = await RcloneRCClient.shared.refreshVFSTree(dir: dir, recursive: false)
            }
        }
    }

    private func startDaemonHealthWatchdog() {
        healthMonitorTask?.cancel()
        healthMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self = self, self.isMounted, !self.isBusy else { continue }

                if let proc = self.rcloneProcess, !proc.isRunning {
                    NSLog("[ZeroDrive] Watchdog detected rclone exited — attempting hitless recovery...")
                    if await self.respawnDaemonHitlessly() {
                        continue
                    }
                    self.isMounted = false
                    self.statusMessage = "Reconnecting drive…"
                    await self.mountUnifiedDrive()
                    continue
                }

                let pingOk = await RcloneRCClient.shared.ping()
                let mountOk = pingOk ? (await self.probeMountLiveness(timeoutSeconds: 8.0)) : false

                if pingOk && mountOk {
                    self.consecutiveHealthFailures = 0
                    await self.healPoisonedQueueItemsIfNeeded()
                } else {
                    self.consecutiveHealthFailures += 1
                    NSLog("[ZeroDrive] Watchdog health probe warning (%d/6): ping=%d mount=%d",
                          self.consecutiveHealthFailures, pingOk ? 1 : 0, mountOk ? 1 : 0)
                    // Require 6 consecutive failures (~90s) so large cloud operations NEVER trigger false restarts,
                    // and ALWAYS attempt hitless TCP daemon respawn before touching `umount`!
                    if self.consecutiveHealthFailures >= 6 {
                        self.consecutiveHealthFailures = 0
                        NSLog("[ZeroDrive] Watchdog detected prolonged daemon stall — attempting hitless daemon restart...")
                        if await self.respawnDaemonHitlessly() {
                            continue
                        }
                        await self.forceCleanStaleMounts()
                        self.rcloneProcess?.terminate()
                        self.rcloneProcess = nil
                        self.isMounted = false
                        self.statusMessage = "Reconnecting drive…"
                        await self.mountUnifiedDrive()
                    }
                }
            }
        }
    }

    private func healPoisonedQueueItemsIfNeeded() async {
        let queue = await RcloneRCClient.shared.fetchVFSQueue()
        for item in queue where item.tries >= 3 {
            let errLower = (item.errorText ?? "").lowercased()
            if item.name == ".metadata_never_index" || errLower.contains("directory not found") {
                NSLog("[ZeroDrive] Purging poisoned virtual-root queue item: %@ (tries=%d)", item.name, item.tries)
                _ = await RcloneRCClient.shared.forgetFile(relativePath: item.name)
                cleanPoisonedCacheEntries()
            } else if errLower.contains("failed to transfer file from cache to remote") {
                // Local VFS cache file was deleted while vfsMeta remained orphaned
                let localCachedData = cacheDir.appendingPathComponent("vfs/ZeroDriveUnified").appendingPathComponent(item.name)
                if !FileManager.default.fileExists(atPath: localCachedData.path) {
                    let metaFile = cacheDir.appendingPathComponent("vfsMeta/ZeroDriveUnified").appendingPathComponent(item.name)
                    try? FileManager.default.removeItem(at: metaFile)
                    _ = await RcloneRCClient.shared.forgetFile(relativePath: item.name)
                    NSLog("[ZeroDrive] Removed orphaned vfsMeta queue item with missing local cache file: %@", item.name)
                }
            } else if errLower.contains("object not found") && item.tries >= 5 {
                let parentDir = (item.name as NSString).deletingLastPathComponent
                let refreshTarget = parentDir.isEmpty ? "My Drive" : parentDir
                NSLog("[ZeroDrive] Refreshing stale VFS parent '%@' for stuck item '%@' (tries=%d)", refreshTarget, item.name, item.tries)
                _ = await RcloneRCClient.shared.refreshVFSTree(dir: refreshTarget, recursive: false)
            }
        }
    }

    /// Checks whether the macOS kernel mount table currently has an NFS mount at ~/.zerodrive
    /// (uses `/sbin/mount` kernel table so it returns in <5ms even while port 55730 is down awaiting hitless respawn!)
    private func isKernelNFSMounted() async -> Bool {
        return await checkMountTableHasZeroDriveNFS()
    }

    private func checkMountTableHasZeroDriveNFS() async -> Bool {
        let targetPath = nfsMountRoot.path
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/sbin/mount")
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = FileHandle.nullDevice
                do {
                    try proc.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    let text = String(data: data, encoding: .utf8) ?? ""
                    let matched = text.components(separatedBy: .newlines).contains { line in
                        line.contains(" on \(targetPath) (nfs")
                    }
                    continuation.resume(returning: matched)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Runs a real bounded child-process check against ~/.zerodrive so @MainActor NEVER blocks in kernel D-state
    private func probeMountLiveness(timeoutSeconds: Double = 6.0) async -> Bool {
        guard await checkMountTableHasZeroDriveNFS() else { return false }
        return await runBoundedMountCheck(arguments: [nfsMountRoot.path], executable: "/bin/ls", timeoutSeconds: timeoutSeconds) { output in
            return output.contains("My Drive")
        }
    }

    private func runBoundedMountCheck(
        arguments: [String],
        executable: String = "/usr/bin/stat",
        timeoutSeconds: Double,
        validator: @Sendable @escaping (String) -> Bool
    ) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = arguments
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = FileHandle.nullDevice

                let lock = NSLock()
                var resumed = false
                let finish: (Bool) -> Void = { val in
                    lock.lock()
                    defer { lock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: val)
                }

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                    if proc.isRunning {
                        proc.terminate()
                    }
                    finish(false)
                }

                do {
                    try proc.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    guard proc.terminationStatus == 0 else {
                        finish(false)
                        return
                    }
                    let out = String(data: data, encoding: .utf8) ?? ""
                    finish(validator(out))
                } catch {
                    finish(false)
                }
            }
        }
    }

    private func cleanPoisonedCacheEntries() {
        let fm = FileManager.default
        let poisonedPaths = [
            cacheDir.appendingPathComponent("vfs/ZeroDriveUnified/.metadata_never_index"),
            cacheDir.appendingPathComponent("vfsMeta/ZeroDriveUnified/.metadata_never_index")
        ]
        for url in poisonedPaths {
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }

        // Purge any orphaned vfsMeta JSON entries whose backing vfs data file is missing
        let vfsRoot = cacheDir.appendingPathComponent("vfs/ZeroDriveUnified")
        let vfsMetaRoot = cacheDir.appendingPathComponent("vfsMeta/ZeroDriveUnified")
        if let enumerator = fm.enumerator(at: vfsMetaRoot, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let metaURL as URL in enumerator {
                guard (try? metaURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let rel = metaURL.path.replacingOccurrences(of: vfsMetaRoot.path + "/", with: "")
                let vfsCounterpart = vfsRoot.appendingPathComponent(rel)
                if !fm.fileExists(atPath: vfsCounterpart.path),
                   let data = try? Data(contentsOf: metaURL),
                   let str = String(data: data, encoding: .utf8),
                   str.contains("\"Dirty\":true") || str.contains("\"dirty\":true") {
                    try? fm.removeItem(at: metaURL)
                    NSLog("[ZeroDrive] Cleaned orphaned dirty vfsMeta entry without backing file: %@", rel)
                }
            }
        }
    }

    private func forceCleanStaleMounts() async {
        let legacyMount = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zerodrive-mount").path
        // Unmount ONLY paths currently present in /sbin/mount, BEFORE killing rclone, and with a strict timeout so kernel dounmount stalls never hang ZeroDrive!
        for path in [nfsMountRoot.path, userSymlinkURL.path, legacyMount] {
            if await checkMountTableHasPath(path) {
                let ok = await runCommandBounded("/sbin/umount", [path], timeoutSeconds: 3.0)
                if !ok {
                    _ = await runCommandBounded("/sbin/umount", ["-f", path], timeoutSeconds: 4.0)
                }
            }
        }
        await runCommand("/usr/bin/pkill", ["-f", "rclone nfsmount ZeroDriveUnified:"])
        await runCommand("/usr/bin/pkill", ["-f", "rclone serve nfs ZeroDriveUnified:"])
        cleanupRotatedStaleMountDirs()
    }

    private func checkMountTableHasPath(_ targetPath: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/sbin/mount")
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = FileHandle.nullDevice
                do {
                    try proc.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    let text = String(data: data, encoding: .utf8) ?? ""
                    let matched = text.components(separatedBy: .newlines).contains { line in
                        line.contains(" on \(targetPath) (")
                    }
                    continuation.resume(returning: matched)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func rotateWedgedMountDirectoryInode() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let backup = home.appendingPathComponent(".zerodrive-stale-\(Int(Date().timeIntervalSince1970))")
        if fm.fileExists(atPath: nfsMountRoot.path) {
            try? fm.moveItem(at: nfsMountRoot, to: backup)
        }
        try? fm.createDirectory(at: nfsMountRoot, withIntermediateDirectories: true)
        NSLog("[ZeroDrive] Rotated wedged mount directory inode to fresh directory at %@", nfsMountRoot.path)
    }

    private func cleanupRotatedStaleMountDirs() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        guard let items = try? fm.contentsOfDirectory(atPath: home.path) else { return }
        for item in items where item.hasPrefix(".zerodrive-stale") {
            let url = home.appendingPathComponent(item)
            try? fm.removeItem(at: url)
        }
    }

    @discardableResult
    private func runCommandBounded(_ executable: String, _ arguments: [String], timeoutSeconds: Double) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: executable)
                task.arguments = arguments
                task.standardOutput = FileHandle.nullDevice
                task.standardError = FileHandle.nullDevice

                let lock = NSLock()
                var resumed = false
                let finish: (Bool) -> Void = { ok in
                    lock.lock()
                    defer { lock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: ok)
                }

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                    if task.isRunning {
                        task.terminate()
                    }
                    finish(false)
                }

                do {
                    try task.run()
                    task.waitUntilExit()
                    finish(task.terminationStatus == 0)
                } catch {
                    finish(false)
                }
            }
        }
    }

    private var cachedRcloneBinaryURL: URL? = nil

    public func resolveRcloneBinary() -> URL? {
        if let cached = cachedRcloneBinaryURL,
           FileManager.default.isExecutableFile(atPath: cached.path) {
            return cached
        }

        if let bundled = Bundle.main.url(forResource: "rclone", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            cachedRcloneBinaryURL = bundled
            return bundled
        }

        let candidates: [URL?] = [
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("ZeroDrive/bin/rclone"),
            URL(fileURLWithPath: "/Applications/ZeroDrive.app/Contents/Resources/rclone"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/ZeroDrive/bin/rclone"),
            URL(fileURLWithPath: "/usr/local/bin/rclone"),
            URL(fileURLWithPath: "/opt/homebrew/bin/rclone")
        ]

        for candidate in candidates.compactMap({ $0 }) {
            if FileManager.default.isExecutableFile(atPath: candidate.path),
               verifySupportsNFSMount(candidate) {
                cachedRcloneBinaryURL = candidate
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
        statusMessage = "Downloading ZeroDrive streaming engine..."
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

    nonisolated private func verifySupportsNFSMount(_ binaryURL: URL) -> Bool {
        DispatchQueue.global(qos: .userInitiated).sync {
            let proc = Process()
            proc.executableURL = binaryURL
            proc.arguments = ["serve", "nfs", "--help"]
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
    }

    private func ensureUserSymlink() {
        let fm = FileManager.default
        let destinationURL = nfsMountRoot.appendingPathComponent("My Drive")
        if let dest = try? fm.destinationOfSymbolicLink(atPath: userSymlinkURL.path), dest == destinationURL.path {
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
            try? fm.createSymbolicLink(at: userSymlinkURL, withDestinationURL: destinationURL)
        }
    }

    public func ensureMetadataNeverIndex() {
        // Only write inside "My Drive" (never at virtual combine root ~/.zerodrive-mount) and off @MainActor
        let target = nfsMountRoot.appendingPathComponent("My Drive/.metadata_never_index")
        Task.detached(priority: .utility) {
            if !FileManager.default.fileExists(atPath: target.path) {
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

    /// Pins My Drive into Finder's Sidebar Favorites via modern CLI or LaunchServices
    public func pinToFinderSidebarIfNeeded() {
        guard isMounted else { return }
        let driveURL = mountPoint.appendingPathComponent("My Drive", isDirectory: true)

        let mysidesPaths = ["/opt/homebrew/bin/mysides", "/usr/local/bin/mysides"]
        if let mysidesPath = mysidesPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            let listProc = Process()
            listProc.executableURL = URL(fileURLWithPath: mysidesPath)
            listProc.arguments = ["list"]
            let outPipe = Pipe()
            listProc.standardOutput = outPipe
            listProc.standardError = Pipe()
            try? listProc.run()
            listProc.waitUntilExit()

            let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let lines = output.components(separatedBy: .newlines)

            if lines.contains(where: { $0.hasPrefix("ZeroDrive ->") }) {
                let rmZero = Process()
                rmZero.executableURL = URL(fileURLWithPath: mysidesPath)
                rmZero.arguments = ["remove", "ZeroDrive"]
                try? rmZero.run()
                rmZero.waitUntilExit()
            }

            if let myDriveLine = lines.first(where: { $0.hasPrefix("My Drive ->") }) {
                if !myDriveLine.contains("NOTFOUND") {
                    return
                }
                let rmStale = Process()
                rmStale.executableURL = URL(fileURLWithPath: mysidesPath)
                rmStale.arguments = ["remove", "My Drive"]
                try? rmStale.run()
                rmStale.waitUntilExit()
            }

            let insProc = Process()
            insProc.executableURL = URL(fileURLWithPath: mysidesPath)
            insProc.arguments = ["insert", "My Drive", driveURL.absoluteString]
            try? insProc.run()
            insProc.waitUntilExit()
            return
        }

        let targetURL = mountPoint.appendingPathComponent("My Drive")

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
