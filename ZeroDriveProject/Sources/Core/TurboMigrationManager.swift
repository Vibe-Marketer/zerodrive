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

@MainActor
public final class TurboMigrationManager: ObservableObject {
    public static let shared = TurboMigrationManager()

    @Published public var telemetry: TurboMigrationTelemetry = TurboMigrationTelemetry()
    @Published public var queuedSpaces: [String] = []
    @Published public var queuedPathMap: [String: String] = [:]
    @Published public var ledger: MigrationLedger? = nil
    @Published public var symlinks: [SymlinkEntry] = []

    private let telemetryFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/rclone/migration-telemetry.json")
    private let ledgerFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/rclone/migration-ledger.json")
    private let symlinksFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/rclone/zerodrive-symlinks.json")

    private var pollerTimer: Timer?

    private init() {
        readLedger()
        readSymlinks()
        startPoller()
    }

    public func startPoller() {
        pollerTimer?.invalidate()
        pollerTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.readTelemetry()
                self?.readLedger()
                self?.readSymlinks()
            }
        }
    }

    private func readTelemetry() {
        guard let data = try? Data(contentsOf: telemetryFile),
              let t = try? JSONDecoder().decode(TurboMigrationTelemetry.self, from: data) else {
            return
        }
        self.telemetry = t
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
        if !queuedSpaces.contains(spaceName) {
            queuedSpaces.append(spaceName)
        }
        let spacesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage/FabricDrive/Andrew Naegeles Workspace/Spaces")
        queuedPathMap[spaceName] = spacesDir.appendingPathComponent(spaceName).path
    }

    public func stageAllSpaces(_ spaceNames: [String]) {
        for name in spaceNames {
            stageSpace(name)
        }
    }

    public func stageURLs(_ urls: [URL]) {
        for url in urls {
            let name = url.lastPathComponent
            if name.hasPrefix(".") || name.isEmpty { continue }
            if !queuedSpaces.contains(name) {
                queuedSpaces.append(name)
            }
            queuedPathMap[name] = url.path
        }
    }

    public func clearQueue() {
        queuedSpaces.removeAll()
        queuedPathMap.removeAll()
    }

    public func unstageSpace(_ spaceName: String) {
        queuedSpaces.removeAll { $0 == spaceName }
        queuedPathMap.removeValue(forKey: spaceName)
    }

    public func runQueuedMoves() {
        guard !queuedSpaces.isEmpty, !telemetry.isRunning else { return }
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
        if urls.count == 1 {
            let url = urls[0]
            let destName = destinationSubfolder.isEmpty ? url.lastPathComponent : destinationSubfolder
            runScript(
                sourcePath: url.path,
                destSubfolder: destName,
                isCopy: isCopy,
                leaveSymlink: leaveSymlink
            )
        } else {
            stageURLs(urls)
            if !telemetry.isRunning {
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
                self.telemetry.isRunning = false
                self.telemetry.isComplete = true
                self.readTelemetry()
                self.readLedger()
                self.readSymlinks()
                VaultStats.shared.refreshFromCache()
                if let rclone = RcloneDaemonSupervisor.shared.resolveRcloneBinary() {
                    Task { await VaultStats.shared.refresh(rclone: rclone) }
                }
                if !self.queuedSpaces.isEmpty {
                    self.runQueuedMoves()
                }
            }
        }
    }

    public func cancel() {
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k.arguments = ["-f", "turbo-migrate-dashboard.py"]
        try? k.run()
        telemetry.isRunning = false
        telemetry.statusMessage = "Transfer stopped."
    }
}
