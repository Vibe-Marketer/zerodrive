import Foundation

public struct TurboMigrationTelemetry: Codable, Sendable, Equatable {
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

public struct MigrationLedger: Codable, Sendable, Equatable {
    public var baselineMacFreeBytes: Int64
    public var currentMacFreeBytes: Int64
    public var totalFreedOnMacBytes: Int64
    public var totalMovedToVaultBytes: Int64
    public var completedSpaces: [CompletedSpaceEntry]

    public struct CompletedSpaceEntry: Codable, Sendable, Identifiable, Equatable {
        public var id: String { spaceName }
        public var spaceName: String
        public var filesMoved: Int
        public var bytesMoved: Int64
        public var completedAt: String
        public var status: String
    }
}

public struct SymlinkEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: String { originalPath }
    public var folderName: String
    public var originalPath: String
    public var cloudTargetPath: String
    public var bytesSaved: Int64
    public var createdAt: String
}

public struct ConnectedNodeStatus: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var customName: String?
    public var kind: String       // "mac", "windows", "linux", "cloud_stream", "vault", "external_drive"
    public var icon: String
    public var isOnline: Bool
    public var statusBadge: String
    public var subtitle: String
    public var activeActivity: String
    public var freeBytes: Int64
    public var totalBytes: Int64
    public var mountPath: String
    public var chip: String?
    public var os: String?
    public var gpu: String?
    public var ramGB: Int?
    public var lastHeartbeatSecondsAgo: Int?

    public init(
        id: String,
        name: String,
        kind: String,
        icon: String,
        isOnline: Bool,
        statusBadge: String,
        subtitle: String,
        activeActivity: String = "",
        freeBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        mountPath: String = "",
        customName: String? = nil,
        chip: String? = nil,
        os: String? = nil,
        gpu: String? = nil,
        ramGB: Int? = nil,
        lastHeartbeatSecondsAgo: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.customName = customName
        self.kind = kind
        self.icon = icon
        self.isOnline = isOnline
        self.statusBadge = statusBadge
        self.subtitle = subtitle
        self.activeActivity = activeActivity
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
        self.mountPath = mountPath
        self.chip = chip
        self.os = os
        self.gpu = gpu
        self.ramGB = ramGB
        self.lastHeartbeatSecondsAgo = lastHeartbeatSecondsAgo
    }

    public var displayName: String {
        if let custom = customName, !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return custom
        }
        return name
    }

    public var formattedFreeSpace: String {
        if freeBytes > 0 && totalBytes > 0 {
            let freeStr = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
            let totalStr = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            return "\(freeStr) free of \(totalStr)"
        } else if freeBytes > 0 {
            return "\(ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)) free"
        }
        return "Space unknown"
    }

    public var freePercentage: Double? {
        guard totalBytes > 0 else { return nil }
        return Double(freeBytes) / Double(totalBytes) * 100.0
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
    @Published public var localTelemetry: TurboMigrationTelemetry = TurboMigrationTelemetry()
    @Published public var remoteTelemetry: TurboMigrationTelemetry? = nil
    @Published public var queuedSpaces: [String] = []
    @Published public var queuedPathMap: [String: String] = [:]
    @Published public var queuedJobs: [QueuedTransferJob] = []
    @Published public var ledger: MigrationLedger? = nil
    @Published public var symlinks: [SymlinkEntry] = []
    @Published public var connectedNodes: [ConnectedNodeStatus] = []
    @Published public var connectedDevices: [ConnectedNodeStatus] = []
    @Published public var cloudVaults: [ConnectedNodeStatus] = []
    @Published public var cloudStreams: [ConnectedNodeStatus] = []
    @Published public private(set) var isLocalProcessActive: Bool = false

    private let telemetryFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/rclone/migration-telemetry.json")
    private let remoteTelemetryFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/rclone/remote-migration-telemetry.json")
    private let ledgerFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/rclone/migration-ledger.json")
    private let symlinksFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/rclone/zerodrive-symlinks.json")

    private let fleetCacheDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/rclone/fleet-machines-cache")

    private var pollerTimer: Timer?
    private var remotePollerTimer: Timer?
    private var isPollingRemote: Bool = false
    private var lastLedgerReadAt: Date = .distantPast
    private var lastFleetSyncAt: Date = .distantPast
    private let localMachineHost: String = {
        let host = Host.current().localizedName?.lowercased() ?? ProcessInfo.processInfo.hostName.lowercased()
        if host.contains("naegele-mm") { return "naegele-mm" }
        if host.contains("mike") { return "mike-mm" }
        return "naegele-pro"
    }()

    public var isLocalTransferRunning: Bool {
        if isLocalProcessActive { return true }
        return localTelemetry.isRunning && !localTelemetry.sourceLocation.contains("naegele-mm")
    }

    public var isRemoteStreamActive: Bool {
        if let rem = remoteTelemetry, rem.isRunning { return true }
        return false
    }

    private init() {
        try? FileManager.default.createDirectory(at: fleetCacheDir, withIntermediateDirectories: true)
        readLedger()
        readSymlinks()
        readTelemetry()
        refreshConnectedNodes(remoteTelemetry: remoteTelemetry, miniOnline: true, miniFreeBytes: 76_890_652_672)
        startPoller()
    }

    public func startPoller() {
        pollerTimer?.invalidate()
        pollerTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.readTelemetry()
                if Date().timeIntervalSince(self.lastLedgerReadAt) >= 15.0 {
                    self.lastLedgerReadAt = Date()
                    self.readLedger()
                    self.readSymlinks()
                }
            }
        }

        remotePollerTimer?.invalidate()
        remotePollerTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollRemoteMiniAndConnections()
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.pollRemoteMiniAndConnections()
        }
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

        if let loc = localT, self.localTelemetry != loc {
            self.localTelemetry = loc
        }
        if self.remoteTelemetry != remoteT {
            self.remoteTelemetry = remoteT
        }

        // Menu bar & combined telemetry: prefer local running job; if local is idle and remote is running, expose remote for Menu Bar
        let nextTelemetry: TurboMigrationTelemetry? = {
            if let loc = localT, loc.isRunning { return loc }
            if let rem = remoteT, rem.isRunning { return rem }
            if let rem = remoteT, rem.isComplete, (localT == nil || !localT!.isComplete) { return rem }
            return localT
        }()
        if let next = nextTelemetry, self.telemetry != next {
            self.telemetry = next
        }
    }

    private func pollRemoteMiniAndConnections() {
        guard !isPollingRemote else { return }
        isPollingRemote = true

        let dstPath = remoteTelemetryFile.path
        let sshKeyPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/id_ed25519").path
        let isRunningOnMini = (localMachineHost == "naegele-mm")
        let shouldSyncFleet = Date().timeIntervalSince(lastFleetSyncAt) >= 25.0
        if shouldSyncFleet {
            lastFleetSyncAt = Date()
        }
        let rcloneBin = RcloneDaemonSupervisor.shared.resolveRcloneBinary()
        let meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
        let configPath = MultiCloudCombineBuilder.shared.configPath.path
        let fleetDstPath = fleetCacheDir.path

        Task.detached(priority: .utility) {
            // 1. Sync _SYSTEM/MACHINES directly from S3 to local SSD cache (bypasses go-nfs completely!)
            if shouldSyncFleet, let rclone = rcloneBin {
                let syncProc = Process()
                syncProc.executableURL = rclone
                syncProc.arguments = [
                    "copy",
                    "primary_vault:\(meta.bucketAndPrefix)/_SYSTEM/MACHINES",
                    fleetDstPath,
                    "--config=\(configPath)",
                    "--disable-http2",
                    "--use-server-modtime",
                    "--transfers=4",
                    "--checkers=8",
                    "--contimeout=5s",
                    "--timeout=10s"
                ]
                syncProc.standardOutput = Pipe()
                syncProc.standardError = Pipe()
                do {
                    try syncProc.run()
                    syncProc.waitUntilExit()
                } catch {}
            }

            // 2. Pull live telemetry from naegele-mm (100.114.74.17) over SSH (skip if already running on naegele-mm)
            var miniOnline = isRunningOnMini
            var remoteTelem: TurboMigrationTelemetry? = nil

            if !isRunningOnMini && FileManager.default.fileExists(atPath: sshKeyPath) {
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

                do {
                    try proc.run()
                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    if proc.terminationStatus == 0 {
                        miniOnline = true
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
            }

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

    // MARK: - Fleet Discovery & Custom Device Names

    private var customNamesFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/rclone/zerodrive-device-names.json")
    }

    private var cachedSharedCustomNamesFileURL: URL {
        fleetCacheDir.appendingPathComponent("custom_names.json")
    }

    public func loadCustomDeviceNames() -> [String: String] {
        var names: [String: String] = [:]
        if let data = try? Data(contentsOf: cachedSharedCustomNamesFileURL),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            names.merge(dict) { (_, new) in new }
        }
        if let data = try? Data(contentsOf: customNamesFileURL),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            names.merge(dict) { (_, new) in new }
        }
        return names
    }

    public func renameDevice(id: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        var dict = loadCustomDeviceNames()
        if trimmed.isEmpty {
            dict.removeValue(forKey: id)
        } else {
            dict[id] = trimmed
        }

        if let data = try? JSONEncoder().encode(dict) {
            try? data.write(to: customNamesFileURL, options: .atomic)
            try? data.write(to: cachedSharedCustomNamesFileURL, options: .atomic)
            let localSrc = customNamesFileURL.path
            let rcloneBin = RcloneDaemonSupervisor.shared.resolveRcloneBinary()
            let meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
            let configPath = MultiCloudCombineBuilder.shared.configPath.path
            Task.detached(priority: .utility) {
                guard let rclone = rcloneBin else { return }
                let p = Process()
                p.executableURL = rclone
                p.arguments = [
                    "copyto", localSrc,
                    "primary_vault:\(meta.bucketAndPrefix)/_SYSTEM/MACHINES/custom_names.json",
                    "--config=\(configPath)",
                    "--disable-http2",
                    "--use-server-modtime"
                ]
                p.standardOutput = Pipe()
                p.standardError = Pipe()
                try? p.run()
                p.waitUntilExit()
            }
        }

        refreshConnectedNodes(
            remoteTelemetry: self.remoteTelemetry,
            miniOnline: true,
            miniFreeBytes: 0
        )
    }

    private func findMachinesDirectory() -> URL? {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: fleetCacheDir.path, isDirectory: &isDir), isDir.boolValue {
            return fleetCacheDir
        }
        return nil
    }

    private struct RawMachineHeartbeat: Decodable {
        var name: String?
        var kind: String?
        var ts: Double?
        var host: String?
        var os: String?
        var chip: String?
        var cpus: Int?
        var disk_free_gb: Double?
        var disk_total_gb: Double?
        var mem_total_gb: Double?
        var mem_used_gb: Double?
        var uptime: String?
        var gpu: RawGpuInfo?

        struct RawGpuInfo: Decodable {
            var name: String?
            var vram_used_gb: Double?
            var vram_total_gb: Double?
        }
    }

    private struct RawFleetRegistry: Decodable {
        var machines: [RawFleetMachine]?

        struct RawFleetMachine: Decodable {
            var name: String
            var host: String?
            var ip: String?
            var user: String?
            var os: String?
            var chip: String?
            var memory_gb: Int?
            var roles: [String]?
            var work_dir: String?
            var notes: String?
        }
    }

    private func refreshConnectedNodes(
        remoteTelemetry: TurboMigrationTelemetry?,
        miniOnline: Bool,
        miniFreeBytes: Int64
    ) {
        let customNames = loadCustomDeviceNames()
        let now = Date().timeIntervalSince1970

        // 1. Gather dynamic machine status files from _SYSTEM/MACHINES/status/*.json and fleet.json
        var discoveredHeartbeats: [String: RawMachineHeartbeat] = [:]
        var fleetMachines: [String: RawFleetRegistry.RawFleetMachine] = [:]

        if let machinesDir = findMachinesDirectory() {
            // Read fleet.json
            let fleetURL = machinesDir.appendingPathComponent("fleet.json")
            if let fData = try? Data(contentsOf: fleetURL),
               let parsedFleet = try? JSONDecoder().decode(RawFleetRegistry.self, from: fData),
               let list = parsedFleet.machines {
                for m in list {
                    fleetMachines[m.name] = m
                }
            }

            // Read status/*.json
            let statusDir = machinesDir.appendingPathComponent("status")
            if let files = try? FileManager.default.contentsOfDirectory(at: statusDir, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension.lowercased() == "json" {
                    if file.lastPathComponent.hasPrefix(".") { continue }
                    if let sData = try? Data(contentsOf: file),
                       let hb = try? JSONDecoder().decode(RawMachineHeartbeat.self, from: sData) {
                        let mName = hb.name ?? file.deletingPathExtension().lastPathComponent
                        discoveredHeartbeats[mName] = hb
                    }
                }
            }
        }

        // Canonical set of machines to show (fleet + status + fallback default nodes)
        var allMachineIDs = Set<String>(["naegele-pro", "naegele-mm", "mike-mm", "naegele-pc"])
        allMachineIDs.formUnion(fleetMachines.keys)
        allMachineIDs.formUnion(discoveredHeartbeats.keys)

        // Read local Mac SSD filesystem attributes
        let localFileSystemAttrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let localFreeBytes = (localFileSystemAttrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let localTotalBytes = (localFileSystemAttrs?[.systemSize] as? NSNumber)?.int64Value ?? 0

        var devices: [ConnectedNodeStatus] = []

        for mID in allMachineIDs {
            let hb = discoveredHeartbeats[mID]
            let fleet = fleetMachines[mID]
            let isThisMac = (mID == localMachineHost)

            // Determine friendly default name
            let defaultName: String = {
                if mID == "naegele-pro" { return isThisMac ? "naegele-pro (This MacBook Pro)" : "naegele-pro (MacBook Pro)" }
                if mID == "naegele-mm" { return isThisMac ? "naegele-mm (This Mac mini M4 #1)" : "naegele-mm (Mac mini M4 #1)" }
                if mID == "mike-mm" { return isThisMac ? "mike-mm (This Mac mini M4 #2)" : "mike-mm (Mac mini M4 #2)" }
                if mID == "naegele-pc" { return "naegele-pc (Windows RTX 3090 Rig)" }
                return mID
            }()

            // Kind and Icon
            let kind: String = {
                if let k = hb?.kind { return k }
                if let o = fleet?.os?.lowercased(), o.contains("win") { return "windows" }
                if mID.contains("pc") { return "windows" }
                return "mac"
            }()

            let icon: String = {
                if isThisMac { return "laptopcomputer" }
                if mID.contains("mm") || (fleet?.chip?.contains("M4") == true) { return "macmini.fill" }
                if kind == "windows" || mID.contains("pc") { return "display" }
                if kind == "linux" { return "server.rack" }
                return "desktopcomputer"
            }()

            // Mount path
            let mountPath: String = {
                if isThisMac { return "~/ZeroDrive & ~/.zerodrive-mount/My Drive" }
                if mID == "naegele-pc" { return "C:\\Users\\andre\\ZeroDrive & /zerodrive" }
                if mID.contains("mm") { return "~/ZeroDrive/My Drive" }
                if let w = fleet?.work_dir, !w.isEmpty { return w }
                return "~/ZeroDrive"
            }()

            // Storage free & total
            let freeB: Int64
            let totalB: Int64
            if isThisMac && localFreeBytes > 0 {
                freeB = localFreeBytes
                totalB = localTotalBytes
            } else if let df = hb?.disk_free_gb, let dt = hb?.disk_total_gb, dt > 0 {
                freeB = Int64(df * 1024 * 1024 * 1024)
                totalB = Int64(dt * 1024 * 1024 * 1024)
            } else if mID == "naegele-mm" {
                freeB = miniFreeBytes > 0 ? miniFreeBytes : 40 * 1024 * 1024 * 1024
                totalB = 460 * 1024 * 1024 * 1024
            } else if mID == "mike-mm" {
                freeB = 235 * 1024 * 1024 * 1024
                totalB = 460 * 1024 * 1024 * 1024
            } else if mID == "naegele-pc" {
                freeB = 872 * 1024 * 1024 * 1024
                totalB = 1007 * 1024 * 1024 * 1024
            } else {
                freeB = 0
                totalB = 0
            }

            // Specs
            let chip = hb?.chip ?? fleet?.chip ?? (isThisMac ? "Apple M2 Max" : (mID.contains("mm") ? "Apple M4" : "Intel Core i9-10900K"))
            let osDesc = hb?.os ?? fleet?.os ?? (isThisMac ? "macOS" : (mID.contains("mm") ? "macOS" : "Ubuntu 24.04 (WSL2)"))
            let gpuDesc: String? = {
                if let gName = hb?.gpu?.name, !gName.isEmpty {
                    if let vram = hb?.gpu?.vram_total_gb {
                        return "\(gName) (\(Int(vram)) GB)"
                    }
                    return gName
                }
                if mID == "naegele-pc" { return "NVIDIA GeForce RTX 3090 (24 GB)" }
                return nil
            }()
            let ram = hb?.mem_total_gb.map { Int($0.rounded()) } ?? fleet?.memory_gb ?? (isThisMac ? 32 : (mID.contains("mm") ? 24 : 128))

            // Freshness & Online status
            let hbTS = hb?.ts ?? 0
            let ageSeconds = (hbTS > 0) ? (now - hbTS) : 999999
            let isOnline: Bool = {
                if isThisMac { return true }
                if mID == "naegele-mm" && miniOnline { return true }
                return ageSeconds < 300 // Active heartbeat within 5 minutes
            }()

            // Status badge
            let statusBadge: String = {
                if isThisMac {
                    return isLocalTransferRunning ? "Moving Files" : "This Mac • Active"
                }
                if mID == "naegele-mm" && (remoteTelemetry?.isRunning == true) {
                    return "Streaming Live"
                }
                if isOnline {
                    if ageSeconds < 120 {
                        return "Online • Active"
                    }
                    return "Online"
                }
                return "Offline"
            }()

            // Active activity
            let activity: String = {
                if isThisMac && isLocalTransferRunning {
                    return telemetry.statusMessage
                }
                if mID == "naegele-mm", let rt = remoteTelemetry, rt.isRunning {
                    let movedStr = ByteCountFormatter.string(fromByteCount: rt.movedBytes, countStyle: .file)
                    let totStr = ByteCountFormatter.string(fromByteCount: rt.totalBytes, countStyle: .file)
                    return String(format: "⚡ Streaming %@ at %.1f MB/s • %@ / %@ (%d/%d files)", rt.spaceName, rt.speedMBps, movedStr, totStr, rt.movedFiles, rt.totalFiles)
                }
                return ""
            }()

            let freeStr = ByteCountFormatter.string(fromByteCount: freeB, countStyle: .file)
            let totalStr = totalB > 0 ? ByteCountFormatter.string(fromByteCount: totalB, countStyle: .file) : ""
            let storageSub = totalB > 0 ? "\(freeStr) free of \(totalStr) SSD" : "\(freeStr) free"
            let subtitle = "Mounted at \(mountPath) • \(storageSub)"

            devices.append(ConnectedNodeStatus(
                id: mID,
                name: defaultName,
                kind: kind,
                icon: icon,
                isOnline: isOnline,
                statusBadge: statusBadge,
                subtitle: subtitle,
                activeActivity: activity,
                freeBytes: freeB,
                totalBytes: totalB,
                mountPath: mountPath,
                customName: customNames[mID],
                chip: chip,
                os: osDesc,
                gpu: gpuDesc,
                ramGB: ram,
                lastHeartbeatSecondsAgo: (hbTS > 0) ? Int(max(0, ageSeconds)) : nil
            ))
        }

        // Sort devices: This Mac (naegele-pro) first, then minis, then PC, then others
        let orderPriority: [String: Int] = [
            "naegele-pro": 0,
            "naegele-mm": 1,
            "mike-mm": 2,
            "naegele-pc": 3
        ]
        devices.sort { a, b in
            let pA = orderPriority[a.id] ?? 99
            let pB = orderPriority[b.id] ?? 99
            if pA != pB { return pA < pB }
            return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }

        // 2. ZeroDrive Cloud Vaults & Drives
        let meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
        let quotaTB = meta.quotaTB > 0 ? meta.quotaTB : 5.0
        let totalVaultBytes = Int64(quotaTB * 1024 * 1024 * 1024 * 1024)
        let baseVaultBytes = VaultStats.shared.totalBytes ?? ledger?.totalMovedToVaultBytes ?? 0
        let activeMoved = telemetry.isRunning ? telemetry.movedBytes : 0
        let vaultBytes = baseVaultBytes + activeMoved
        let freeVaultBytes = max(0, totalVaultBytes - vaultBytes)

        let freeSizeStr = ByteCountFormatter.string(fromByteCount: freeVaultBytes, countStyle: .file)
        let quotaSizeStr = String(format: "%.1f TB", quotaTB)
        let vaultSizeStr = vaultBytes > 0 ? ByteCountFormatter.string(fromByteCount: vaultBytes, countStyle: .file) : "148+ GB"

        var vaults: [ConnectedNodeStatus] = []
        vaults.append(ConnectedNodeStatus(
            id: "primary-cloud-vault",
            name: "ZeroDrive Cloud Vault",
            kind: "vault",
            icon: "externaldrive.fill.badge.icloud",
            isOnline: true,
            statusBadge: "Primary Vault • Live",
            subtitle: "\(freeSizeStr) free of \(quotaSizeStr) • \(vaultSizeStr) stored in zerodrive-vault-prod • 0 KB local SSD used",
            activeActivity: telemetry.isRunning ? "\(telemetry.statusMessage) at \(String(format: "%.1f MB/s", telemetry.speedMBps))" : "",
            freeBytes: freeVaultBytes,
            totalBytes: totalVaultBytes,
            mountPath: "~/.zerodrive-mount/My Drive"
        ))

        // 3. Direct Cloud-to-Cloud Streams & External Connections
        var streams: [ConnectedNodeStatus] = []
        let confPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/rclone/rclone.conf")
        let confStr = (try? String(contentsOf: confPath, encoding: .utf8)) ?? ""
        if confStr.contains("[icloud_direct]") {
            let icloudActive = (telemetry.isRunning && telemetry.sourceLocation.contains("iCloud"))
            streams.append(ConnectedNodeStatus(
                id: "icloud-direct",
                name: "iCloud Drive Direct API (naegele412@gmail.com)",
                kind: "cloud_stream",
                icon: "icloud.and.arrow.up.fill",
                isOnline: true,
                statusBadge: icloudActive ? "Active Stream (0 Disk)" : "Connected • Ready",
                subtitle: "Direct Apple CloudKit HTTP stream -> ZeroDrive Cloud Vault (bypasses Finder/bird)",
                activeActivity: icloudActive ? "\(telemetry.statusMessage) at \(String(format: "%.1f MB/s", telemetry.speedMBps))" : ""
            ))
        }

        let fabricPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage/FabricDrive")
        if FileManager.default.fileExists(atPath: fabricPath.path) {
            streams.append(ConnectedNodeStatus(
                id: "fabric-drive",
                name: "Fabric Drive (Local CloudStorage)",
                kind: "external_drive",
                icon: "folder.fill.badge.gearshape",
                isOnline: true,
                statusBadge: "Detected",
                subtitle: "Available as a source for Move to Cloud"
            ))
        }

        // Assign published properties only when changed
        if self.connectedDevices != devices { self.connectedDevices = devices }
        if self.cloudVaults != vaults { self.cloudVaults = vaults }
        if self.cloudStreams != streams { self.cloudStreams = streams }
        let combined = devices + vaults + streams
        if self.connectedNodes != combined { self.connectedNodes = combined }
    }

    public func readLedger() {
        guard let data = try? Data(contentsOf: ledgerFile),
              let l = try? JSONDecoder().decode(MigrationLedger.self, from: data) else {
            return
        }
        if self.ledger != l {
            self.ledger = l
        }
    }

    public func readSymlinks() {
        guard let data = try? Data(contentsOf: symlinksFile),
              let s = try? JSONDecoder().decode([SymlinkEntry].self, from: data) else {
            return
        }
        if self.symlinks != s {
            self.symlinks = s
        }
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
        leaveSymlink: Bool = false,
        symlinkPaths: Set<String>? = nil
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
            let itemShouldSymlink: Bool
            if let explicitSet = symlinkPaths {
                itemShouldSymlink = explicitSet.contains(url.path)
            } else {
                itemShouldSymlink = leaveSymlink
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
                leaveSymlink: itemShouldSymlink
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
        leaveSymlink: Bool = false,
        symlinkPaths: Set<String>? = nil
    ) {
        guard !urls.isEmpty else { return }
        if urls.count == 1 && !isLocalProcessActive {
            let url = urls[0]
            let cleanDest = destinationSubfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            let destName = cleanDest.isEmpty ? url.lastPathComponent : cleanDest
            let shouldSymlink = symlinkPaths?.contains(url.path) ?? leaveSymlink
            runScript(
                sourcePath: url.path,
                destSubfolder: destName,
                isCopy: isCopy,
                leaveSymlink: shouldSymlink
            )
        } else {
            stageURLs(
                urls,
                destinationSubfolder: destinationSubfolder,
                isCopy: isCopy,
                leaveSymlink: leaveSymlink,
                symlinkPaths: symlinkPaths
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
        localTelemetry.spaceName = name
        localTelemetry.isRunning = true
        localTelemetry.statusMessage = "Preparing \(isCopy ? "copy" : "move") for \(name)…"
        localTelemetry.sourceLocation = "\(prefix): \(name)"
        localTelemetry.destLocation = "My Drive/\(name)"
        telemetry = localTelemetry

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
                self.localTelemetry.isRunning = false
                self.localTelemetry.isComplete = true
                self.readTelemetry()
                self.readLedger()
                self.readSymlinks()
                VaultStats.shared.refreshFromCache()
                if let rclone = RcloneDaemonSupervisor.shared.resolveRcloneBinary() {
                    Task { await VaultStats.shared.refresh(rclone: rclone, forceFullSize: true) }
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
