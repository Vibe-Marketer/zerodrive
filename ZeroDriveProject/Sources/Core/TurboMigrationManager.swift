import Foundation

public struct TurboMigrationTelemetry: Codable, Sendable {
    public var spaceName: String
    public var isRunning: Bool
    public var isComplete: Bool
    public var speedMBps: Double
    public var percent: Double
    public var movedFiles: Int
    public var totalFiles: Int
    public var movedBytes: Int64
    public var totalBytes: Int64
    public var remainingBytes: Int64
    public var etaSeconds: Int
    public var freeDiskBytes: Int64
    public var diskDeltaBytes: Int64
    public var activeWorkers: Int
    public var statusMessage: String
    public var currentFile: String
    public var sourceLocation: String
    public var destLocation: String

    public init(
        spaceName: String = "",
        isRunning: Bool = false,
        isComplete: Bool = false,
        speedMBps: Double = 0.0,
        percent: Double = 0.0,
        movedFiles: Int = 0,
        totalFiles: Int = 0,
        movedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        remainingBytes: Int64 = 0,
        etaSeconds: Int = 0,
        freeDiskBytes: Int64 = 0,
        diskDeltaBytes: Int64 = 0,
        activeWorkers: Int = 32,
        statusMessage: String = "Ready",
        currentFile: String = "",
        sourceLocation: String = "",
        destLocation: String = ""
    ) {
        self.spaceName = spaceName
        self.isRunning = isRunning
        self.isComplete = isComplete
        self.speedMBps = speedMBps
        self.percent = percent
        self.movedFiles = movedFiles
        self.totalFiles = totalFiles
        self.movedBytes = movedBytes
        self.totalBytes = totalBytes
        self.remainingBytes = remainingBytes
        self.etaSeconds = etaSeconds
        self.freeDiskBytes = freeDiskBytes
        self.diskDeltaBytes = diskDeltaBytes
        self.activeWorkers = activeWorkers
        self.statusMessage = statusMessage
        self.currentFile = currentFile
        self.sourceLocation = sourceLocation
        self.destLocation = destLocation
    }
}

public struct MigrationLedger: Codable, Sendable {
    public var baselineMacFreeBytes: Int64
    public var currentMacFreeBytes: Int64
    public var totalFreedOnMacBytes: Int64
    public var totalMovedToVaultBytes: Int64
    public var completedSpaces: [CompletedSpaceEntry]

    public struct CompletedSpaceEntry: Codable, Sendable, Identifiable {
        public var id: String { spaceName }
        public var spaceName: String
        public var filesMoved: Int
        public var bytesMoved: Int64
        public var completedAt: String
        public var status: String
    }
}

public struct SymlinkEntry: Codable, Sendable, Identifiable {
    public var id: String { originalPath }
    public var folderName: String
    public var originalPath: String
    public var cloudTargetPath: String
    public var bytesSaved: Int64
    public var createdAt: String
}

public struct ConnectedNodeStatus: Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: String       // "mac", "cloud_stream", "vault", "external_drive"
    public var icon: String
    public var isOnline: Bool
    public var statusBadge: String
    public var subtitle: String
    public var activeActivity: String
    public var freeBytes: Int64

    public init(
        id: String,
        name: String,
        kind: String,
        icon: String,
        isOnline: Bool,
        statusBadge: String,
        subtitle: String,
        activeActivity: String = "",
        freeBytes: Int64 = 0
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.icon = icon
        self.isOnline = isOnline
        self.statusBadge = statusBadge
        self.subtitle = subtitle
        self.activeActivity = activeActivity
        self.freeBytes = freeBytes
    }
}

public struct QueuedTransferJob: Identifiable, Equatable {
    public var id: String { sourcePath }
    public var name: String
    public var sourcePath: String
    public var destSubfolder: String
    public var isCopy: Bool
    public var leaveSymlink: Bool

    public init(
        name: String,
        sourcePath: String,
        destSubfolder: String,
        isCopy: Bool = false,
        leaveSymlink: Bool = false
    ) {
        self.name = name
        self.sourcePath = sourcePath
        self.destSubfolder = destSubfolder
        self.isCopy = isCopy
        self.leaveSymlink = leaveSymlink
    }
}

@MainActor
public final class TurboMigrationManager: ObservableObject {
    public static let shared = TurboMigrationManager()

    @Published public var telemetry: TurboMigrationTelemetry = TurboMigrationTelemetry()
    @Published public var remoteTelemetry: TurboMigrationTelemetry? = nil
    @Published public var queuedSpaces: [String] = []
    @Published public var queuedPathMap: [String: String] = [:]
    @Published public var queuedJobs: [QueuedTransferJob] = []
    @Published public var ledger: MigrationLedger? = nil
    @Published public var symlinks: [SymlinkEntry] = []
    @Published public var connectedNodes: [ConnectedNodeStatus] = []
    @Published public private(set) var isLocalProcessActive: Bool = false

    private let telemetryFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/rclone/migration-telemetry.json")
    private let remoteTelemetryFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/rclone/remote-migration-telemetry.json")
    private let ledgerFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/rclone/migration-ledger.json")
    private let symlinksFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/rclone/zerodrive-symlinks.json")

    private var pollerTimer: Timer?
    private var remotePollerTimer: Timer?
    private var isPollingRemote: Bool = false

    public var isLocalTransferRunning: Bool {
        if isLocalProcessActive { return true }
        return telemetry.isRunning && !telemetry.sourceLocation.contains("naegele-mm")
    }

    public var isRemoteStreamActive: Bool {
        if let rem = remoteTelemetry, rem.isRunning { return true }
        return telemetry.isRunning && telemetry.sourceLocation.contains("naegele-mm")
    }

    private init() {
        readLedger()
        readSymlinks()
        readTelemetry()
        refreshConnectedNodes(remoteTelemetry: remoteTelemetry, miniOnline: true, miniFreeBytes: 76_890_652_672)
        startPoller()
    }

    public func startPoller() {
        pollerTimer?.invalidate()
        pollerTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.readTelemetry()
                self?.readLedger()
                self?.readSymlinks()
            }
        }

        remotePollerTimer?.invalidate()
        remotePollerTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollRemoteMiniAndConnections()
            }
        }
        pollRemoteMiniAndConnections()
    }

    private func readTelemetry() {
        let localT: TurboMigrationTelemetry? = {
            guard let data = try? Data(contentsOf: telemetryFile),
                  let t = try? JSONDecoder().decode(TurboMigrationTelemetry.self, from: data) else {
                return nil
            }
            return t
        }()

        let remoteT: TurboMigrationTelemetry? = {
            guard let data = try? Data(contentsOf: remoteTelemetryFile),
                  let t = try? JSONDecoder().decode(TurboMigrationTelemetry.self, from: data) else {
                return nil
            }
            return t
        }()

        self.remoteTelemetry = remoteT

        // Prefer local running job; if local is idle and remote (e.g. naegele-mm direct iCloud stream) is running, stream remote in UI!
        if let loc = localT, loc.isRunning {
            self.telemetry = loc
        } else if let rem = remoteT, rem.isRunning {
            self.telemetry = rem
        } else if let rem = remoteT, rem.isComplete, (localT == nil || !localT!.isComplete) {
            self.telemetry = rem
        } else if let loc = localT {
            self.telemetry = loc
        }
    }

    private func pollRemoteMiniAndConnections() {
        guard !isPollingRemote else { return }
        isPollingRemote = true

        let dstPath = remoteTelemetryFile.path
        let sshKeyPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/id_ed25519").path

        Task.detached(priority: .utility) {
            // Pull live telemetry from naegele-mm (100.114.74.17) over SSH using explicit key and IP
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = [
                "-i", sshKeyPath,
                "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=no",
                "-o", "ConnectTimeout=2",
                "admin@100.114.74.17",
                "cat /Users/admin/.config/rclone/migration-telemetry.json 2>/dev/null"
            ]
            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = Pipe()

            var miniOnline = false
            var remoteTelem: TurboMigrationTelemetry? = nil

            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    miniOnline = true
                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    if !data.isEmpty, var decoded = try? JSONDecoder().decode(TurboMigrationTelemetry.self, from: data) {
                        if !decoded.sourceLocation.contains("naegele-mm") {
                            decoded.sourceLocation = "\(decoded.sourceLocation) (via naegele-mm)"
                        }
                        if let encoded = try? JSONEncoder().encode(decoded) {
                            try? encoded.write(to: URL(fileURLWithPath: dstPath), options: .atomic)
                        }
                        remoteTelem = decoded
                    }
                }
            } catch {}

            let finalOnline = miniOnline
            let finalTelem = remoteTelem
            await MainActor.run {
                self.isPollingRemote = false
                self.readTelemetry()
                self.refreshConnectedNodes(
                    remoteTelemetry: finalTelem ?? self.remoteTelemetry,
                    miniOnline: finalOnline,
                    miniFreeBytes: finalTelem?.freeDiskBytes ?? 76_890_652_672
                )
            }
        }
    }

    private func refreshConnectedNodes(
        remoteTelemetry: TurboMigrationTelemetry?,
        miniOnline: Bool,
        miniFreeBytes: Int64
    ) {
        var nodes: [ConnectedNodeStatus] = []

        // 1. This Mac (naegele-pro)
        let localFree = Int64((try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())[.systemFreeSize] as? NSNumber)?.int64Value ?? 0)
        let localFreeStr = ByteCountFormatter.string(fromByteCount: localFree, countStyle: .file)
        nodes.append(ConnectedNodeStatus(
            id: "naegele-pro",
            name: "naegele-pro (This MacBook Pro)",
            kind: "mac",
            icon: "laptopcomputer",
            isOnline: true,
            statusBadge: isLocalTransferRunning ? "Moving Files" : "This Mac • Mounted",
            subtitle: "Mounted at ~/ZeroDrive/My Drive • \(localFreeStr) free on SSD",
            activeActivity: isLocalTransferRunning ? telemetry.statusMessage : "",
            freeBytes: localFree
        ))

        // 2. naegele-mm (Mac mini on Tailnet / LAN)
        let miniFreeStr = ByteCountFormatter.string(fromByteCount: miniFreeBytes, countStyle: .file)
        let miniActivity: String = {
            if let rt = remoteTelemetry, rt.isRunning {
                let movedStr = ByteCountFormatter.string(fromByteCount: rt.movedBytes, countStyle: .file)
                let totStr = ByteCountFormatter.string(fromByteCount: rt.totalBytes, countStyle: .file)
                return String(format: "⚡ Streaming %@ at %.1f MB/s • %@ / %@ (%d/%d files)", rt.spaceName, rt.speedMBps, movedStr, totStr, rt.movedFiles, rt.totalFiles)
            }
            return ""
        }()
        nodes.append(ConnectedNodeStatus(
            id: "naegele-mm",
            name: "naegele-mm (Mac mini • 100.114.74.17)",
            kind: "mac",
            icon: "macmini.fill",
            isOnline: miniOnline,
            statusBadge: (remoteTelemetry?.isRunning == true) ? "Streaming Live" : (miniOnline ? "Online • Mounted" : "Offline"),
            subtitle: "Mounted at ~/ZeroDrive/My Drive • \(miniFreeStr) free on SSD",
            activeActivity: miniActivity,
            freeBytes: miniFreeBytes
        ))

        // 3. Direct iCloud Stream Connection (naegele412@gmail.com)
        let confPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/rclone/rclone.conf")
        let confStr = (try? String(contentsOf: confPath, encoding: .utf8)) ?? ""
        let hasICloudDirect = confStr.contains("[icloud_direct]")
        if hasICloudDirect {
            let icloudActive = (telemetry.isRunning && telemetry.sourceLocation.contains("iCloud"))
            nodes.append(ConnectedNodeStatus(
                id: "icloud-direct",
                name: "iCloud Drive Direct API (naegele412@gmail.com)",
                kind: "cloud_stream",
                icon: "icloud.and.arrow.up.fill",
                isOnline: true,
                statusBadge: icloudActive ? "Active Stream (0 Disk)" : "Connected • Ready",
                subtitle: "Direct Apple CloudKit HTTP stream -> Cloudflare R2 Vault (bypasses Finder/bird)",
                activeActivity: icloudActive ? "\(telemetry.statusMessage) at \(String(format: "%.1f MB/s", telemetry.speedMBps))" : ""
            ))
        }

        // 4. Primary Cloudflare R2 Vault
        // IMPORTANT: Read VaultStats.shared.totalBytes directly (never liveTotalBytes) to avoid recursive dispatch_once during TurboMigrationManager.init()!
        let baseVaultBytes = VaultStats.shared.totalBytes ?? ledger?.totalMovedToVaultBytes ?? 0
        let activeMoved = telemetry.isRunning ? telemetry.movedBytes : 0
        let vaultBytes = baseVaultBytes + activeMoved
        let vaultSizeStr = vaultBytes > 0 ? ByteCountFormatter.string(fromByteCount: vaultBytes, countStyle: .file) : "148+ GB"
        nodes.append(ConnectedNodeStatus(
            id: "cloudflare-r2",
            name: "ZeroDrive Cloud Vault (Cloudflare R2)",
            kind: "vault",
            icon: "externaldrive.fill.badge.icloud",
            isOnline: true,
            statusBadge: "Primary Vault",
            subtitle: "\(vaultSizeStr) stored in zerodrive-vault-prod • 0 KB local SSD used"
        ))

        // 5. Fabric Drive (if present locally)
        let fabricPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage/FabricDrive")
        if FileManager.default.fileExists(atPath: fabricPath.path) {
            nodes.append(ConnectedNodeStatus(
                id: "fabric-drive",
                name: "Fabric Drive (Local CloudStorage)",
                kind: "external_drive",
                icon: "folder.fill.badge.gearshape",
                isOnline: true,
                statusBadge: "Detected",
                subtitle: "Available as a source for Move to Cloud"
            ))
        }

        self.connectedNodes = nodes
    }

    public func readLedger() {
        guard let data = try? Data(contentsOf: ledgerFile),
              let l = try? JSONDecoder().decode(MigrationLedger.self, from: data) else {
            return
        }
        self.ledger = l
    }

    public func readSymlinks() {
        guard let data = try? Data(contentsOf: symlinksFile),
              let s = try? JSONDecoder().decode([SymlinkEntry].self, from: data) else {
            return
        }
        self.symlinks = s
    }

    public func stageSpace(_ spaceName: String) {
        let spacesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage/FabricDrive/Andrew Naegeles Workspace/Spaces")
        let path = spacesDir.appendingPathComponent(spaceName).path
        if !queuedSpaces.contains(spaceName) {
            queuedSpaces.append(spaceName)
        }
        queuedPathMap[spaceName] = path
        if !queuedJobs.contains(where: { $0.sourcePath == path }) {
            queuedJobs.append(QueuedTransferJob(name: spaceName, sourcePath: path, destSubfolder: spaceName))
        }
    }

    public func stageAllSpaces(_ spaceNames: [String]) {
        for name in spaceNames {
            stageSpace(name)
        }
    }

    public func stageURLs(
        _ urls: [URL],
        destinationSubfolder: String = "",
        isCopy: Bool = false,
        leaveSymlink: Bool = false
    ) {
        let cleanParent = destinationSubfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        for url in urls {
            let name = url.lastPathComponent
            if name.hasPrefix(".") || name.isEmpty { continue }
            let itemDest: String
            if urls.count == 1 {
                itemDest = cleanParent.isEmpty ? name : cleanParent
            } else {
                // When multiple folders/items are selected, place each item inside the chosen parent folder (or Top Level if empty)
                if cleanParent.isEmpty {
                    itemDest = name
                } else if cleanParent == name {
                    itemDest = name
                } else {
                    itemDest = "\(cleanParent)/\(name)"
                }
            }
            if !queuedSpaces.contains(name) {
                queuedSpaces.append(name)
            }
            queuedPathMap[name] = url.path
            queuedJobs.removeAll { $0.sourcePath == url.path }
            queuedJobs.append(QueuedTransferJob(
                name: name,
                sourcePath: url.path,
                destSubfolder: itemDest,
                isCopy: isCopy,
                leaveSymlink: leaveSymlink
            ))
        }
    }

    public func clearQueue() {
        queuedSpaces.removeAll()
        queuedPathMap.removeAll()
        queuedJobs.removeAll()
    }

    public func unstageSpace(_ spaceName: String) {
        queuedSpaces.removeAll { $0 == spaceName }
        queuedPathMap.removeValue(forKey: spaceName)
        queuedJobs.removeAll { $0.name == spaceName }
    }

    public func runQueuedMoves() {
        guard !isLocalProcessActive else { return }
        if !queuedJobs.isEmpty {
            let job = queuedJobs.removeFirst()
            queuedSpaces.removeAll { $0 == job.name }
            queuedPathMap.removeValue(forKey: job.name)
            runScript(
                sourcePath: job.sourcePath,
                destSubfolder: job.destSubfolder,
                isCopy: job.isCopy,
                leaveSymlink: job.leaveSymlink
            )
            return
        }
        guard !queuedSpaces.isEmpty else { return }
        let spaceToMove = queuedSpaces.removeFirst()
        if let customPath = queuedPathMap.removeValue(forKey: spaceToMove) {
            runScript(sourcePath: customPath, destSubfolder: spaceToMove)
        } else {
            startMove(spaceName: spaceToMove)
        }
    }

    public func startMove(spaceName: String) {
        let spacesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage/FabricDrive/Andrew Naegeles Workspace/Spaces")
        let spaceURL = spacesDir.appendingPathComponent(spaceName)
        runScript(sourcePath: spaceURL.path, destSubfolder: spaceName)
    }

    public func startTransfer(
        urls: [URL],
        destinationSubfolder: String,
        isCopy: Bool = false,
        leaveSymlink: Bool = false
    ) {
        guard !urls.isEmpty else { return }
        if urls.count == 1 && !isLocalProcessActive {
            let url = urls[0]
            let cleanDest = destinationSubfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            let destName = cleanDest.isEmpty ? url.lastPathComponent : cleanDest
            runScript(
                sourcePath: url.path,
                destSubfolder: destName,
                isCopy: isCopy,
                leaveSymlink: leaveSymlink
            )
        } else {
            stageURLs(
                urls,
                destinationSubfolder: destinationSubfolder,
                isCopy: isCopy,
                leaveSymlink: leaveSymlink
            )
            if !isLocalProcessActive {
                runQueuedMoves()
            }
        }
    }

    public func startDirectMove(urls: [URL]) {
        startTransfer(urls: urls, destinationSubfolder: "", isCopy: false, leaveSymlink: false)
    }

    private func runScript(
        sourcePath: String,
        destSubfolder: String,
        isCopy: Bool = false,
        leaveSymlink: Bool = false
    ) {
        let scriptPath = "/Users/Naegele/_LAB/zerodrive/turbo-migrate-dashboard.py"
        let name = destSubfolder.isEmpty ? URL(fileURLWithPath: sourcePath).lastPathComponent : destSubfolder
        let prefix = sourcePath.contains("FabricDrive") ? "Fabric" : (sourcePath.contains("CloudStorage") || sourcePath.contains("Mobile Documents") || sourcePath.contains("Desktop") ? "iCloud" : "Mac")

        isLocalProcessActive = true
        telemetry.spaceName = name
        telemetry.isRunning = true
        telemetry.statusMessage = "Preparing \(isCopy ? "copy" : "move") for \(name)…"
        telemetry.sourceLocation = "\(prefix): \(name)"
        telemetry.destLocation = "My Drive/\(name)"

        Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            var args = ["-dis", "/usr/bin/python3", scriptPath, sourcePath]
            if !destSubfolder.isEmpty {
                args.append(destSubfolder)
            }
            if isCopy {
                args.append("--copy")
            }
            if leaveSymlink && !isCopy {
                args.append("--leave-symlink")
            }
            proc.arguments = args
            try? proc.run()
            proc.waitUntilExit()

            await MainActor.run {
                self.isLocalProcessActive = false
                self.telemetry.isRunning = false
                self.telemetry.isComplete = true
                self.readTelemetry()
                self.readLedger()
                self.readSymlinks()
                VaultStats.shared.refreshFromCache()
                if let rclone = RcloneDaemonSupervisor.shared.resolveRcloneBinary() {
                    Task { await VaultStats.shared.refresh(rclone: rclone) }
                }
                if !self.queuedJobs.isEmpty || !self.queuedSpaces.isEmpty {
                    self.runQueuedMoves()
                }
            }
        }
    }

    public func cancelLocalOnly() {
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k.arguments = ["-f", "turbo-migrate-dashboard.py"]
        try? k.run()
        isLocalProcessActive = false
    }

    public func cancel() {
        cancelLocalOnly()

        // Also stop remote stream on naegele-mm if active
        let sshKeyPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/id_ed25519").path
        Task.detached {
            let sshKill = Process()
            sshKill.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            sshKill.arguments = [
                "-i", sshKeyPath,
                "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=no",
                "admin@100.114.74.17",
                "pkill -f stream-icloud-to-vault.py; pkill -f 'rclone copy icloud_direct'"
            ]
            try? sshKill.run()
        }

        telemetry.isRunning = false
        telemetry.statusMessage = "Transfer stopped."
    }
}
