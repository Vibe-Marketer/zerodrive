import Foundation
import AppKit
import AVFoundation
import Network

@MainActor
public final class SpoolAndGuardManager: ObservableObject {
    public static let shared = SpoolAndGuardManager()

    @Published public private(set) var spoolItems: [SpoolItem] = []
    @Published public var telemetry: Telemetry = Telemetry()
    @Published public private(set) var bandwidthHistory: [BandwidthSample] = []
    @Published public private(set) var apfsStatus: APFSPreFlightResult = APFSPreFlightResult(
        canStage: true,
        isWarning: false,
        isCritical: false,
        freeDiskBytes: 100 * 1024 * 1024 * 1024,
        shortfallBytes: 0,
        warningMessage: "APFS disk storage is healthy."
    )

    private var pollingTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()

    public init() {
        // Seed 30s of initial 0 MB/s samples for smooth SwiftCharts rendering
        let now = Date()
        bandwidthHistory = (0..<30).map { i in
            BandwidthSample(timestamp: now.addingTimeInterval(Double(i - 30) * 2.0), speedMBps: 0.0)
        }
        startNetworkReachabilityMonitor()
        _ = checkAPFSFreeSpace(forBytes: 0)
    }

    public var dirtyFileCount: Int {
        let localDirty = spoolItems.filter {
            $0.status == .staging || $0.status == .uploading || $0.status == .pausedOffline
        }.count
        return max(localDirty, telemetry.activeUploads + telemetry.activeQueued)
    }

    public var dirtyBytes: Int64 {
        let localBytes = spoolItems.filter {
            $0.status == .staging || $0.status == .uploading || $0.status == .pausedOffline
        }.reduce(0) { $0 + $1.sizeBytes }
        return max(localBytes, telemetry.spoolUsedBytes)
    }

    // MARK: - Pre-Flight APFS Free-Space Probing (Hurdle 3 Mitigation)

    public func checkAPFSFreeSpace(forBytes fileSizeBytes: Int64) -> APFSPreFlightResult {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let values = try? homeURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        let freeBytes = values?.volumeAvailableCapacityForImportantUsage
            ?? Int64(values?.volumeAvailableCapacity ?? (50 * 1024 * 1024 * 1024))

        let warningThreshold: Int64 = 15 * 1024 * 1024 * 1024  // 15 GB
        let criticalThreshold: Int64 = 3 * 1024 * 1024 * 1024  // 3 GB
        let requiredBytes = fileSizeBytes + criticalThreshold

        let isCritical = freeBytes < requiredBytes || freeBytes < criticalThreshold
        let isWarning = !isCritical && (freeBytes < warningThreshold || (freeBytes - fileSizeBytes) < warningThreshold)
        let shortfall = max(0, requiredBytes - freeBytes)

        let freeFormatted = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
        let fileFormatted = ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)

        let msg: String
        if isCritical {
            msg = "Critical APFS Disk Pressure: Only \(freeFormatted) free on Macintosh HD. Staging \(fileFormatted) would exhaust local SSD. Use Direct Cloud Upload (Bypass Spool)."
        } else if isWarning {
            msg = "Low APFS Disk Space: \(freeFormatted) remaining (< 15 GB). Consider enabling Direct Cloud Upload (Bypass Spool)."
        } else {
            msg = "APFS disk storage healthy (\(freeFormatted) available)."
        }

        let result = APFSPreFlightResult(
            canStage: !isCritical,
            isWarning: isWarning,
            isCritical: isCritical,
            freeDiskBytes: freeBytes,
            shortfallBytes: shortfall,
            warningMessage: msg
        )
        if result.freeDiskBytes != self.apfsStatus.freeDiskBytes || result.canStage != self.apfsStatus.canStage {
            self.apfsStatus = result
            self.telemetry.freeAPFSBytes = freeBytes
        }
        return result
    }

    // MARK: - Studio Dropzone Handler (Local NVMe Spool vs Direct Cloud Stream Bypass)

    public func handleDroppedURLs(_ urls: [URL], moveAndFreeSpace: Bool, bypassSpool: Bool) async {
        let totalSize = urls.reduce(Int64(0)) { acc, url in
            acc + computeSize(of: url)
        }

        let preflight = checkAPFSFreeSpace(forBytes: totalSize)
        var useDirectBypass = bypassSpool

        if !preflight.canStage && !useDirectBypass {
            let alert = NSAlert()
            alert.messageText = "Low Local Mac SSD Space (\(ByteCountFormatter.string(fromByteCount: preflight.freeDiskBytes, countStyle: .file)) Free)"
            alert.informativeText = preflight.warningMessage
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Stream Directly to Cloud (Bypass Local Spool)")
            alert.addButton(withTitle: "Cancel Drop")
            if alert.runModal() == .alertFirstButtonReturn {
                useDirectBypass = true
            } else {
                return
            }
        }

        let vaultURL = RcloneDaemonSupervisor.shared.mountPoint.appendingPathComponent("Vault")
        try? FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

        for url in urls {
            let size = computeSize(of: url)
            let dest = vaultURL.appendingPathComponent(url.lastPathComponent)
            let duration = await extractMediaDuration(for: url)

            let item = SpoolItem(
                filename: url.lastPathComponent,
                relativePath: "Vault/\(url.lastPathComponent)",
                sizeBytes: size,
                status: telemetry.isOnline ? (useDirectBypass ? .uploading : .staging) : .pausedOffline,
                writeBackRemainingSec: useDirectBypass ? 0 : 15,
                mediaDuration: duration,
                localCachePath: dest
            )
            spoolItems.insert(item, at: 0)

            if useDirectBypass, let rcloneURL = RcloneDaemonSupervisor.shared.resolveRcloneBinary() {
                // Direct Cloud Upload Bypass: streams via multipart HTTPS without writing to ~/.zerodrive-cache
                let itemId = item.id
                Task.detached(priority: .userInitiated) {
                    let proc = Process()
                    proc.executableURL = rcloneURL
                    let subcommand = moveAndFreeSpace ? "move" : "copy"
                    proc.arguments = [
                        subcommand,
                        url.path,
                        "ZeroDriveUnified:Vault/\(url.lastPathComponent)",
                        "--config=\(MultiCloudCombineBuilder.shared.configPath.path)",
                        "--inplace",
                        "--transfers=8"
                    ]
                    try? proc.run()
                    proc.waitUntilExit()
                    await MainActor.run {
                        if let idx = SpoolAndGuardManager.shared.spoolItems.firstIndex(where: { $0.id == itemId }) {
                            SpoolAndGuardManager.shared.spoolItems[idx].status = .synced
                            SpoolAndGuardManager.shared.spoolItems[idx].uploadProgress = 1.0
                        }
                        if moveAndFreeSpace {
                            SpoolAndGuardManager.shared.telemetry.totalSpaceSavedBytes += size
                        }
                    }
                }
            } else {
                if moveAndFreeSpace {
                    try? FileManager.default.moveItem(at: url, to: dest)
                    telemetry.totalSpaceSavedBytes += size
                } else {
                    try? FileManager.default.copyItem(at: url, to: dest)
                }
            }
        }
    }

    // MARK: - Staging & Retakes Triage Actions (PRD Section 7.5)

    public func syncNow(item: SpoolItem) async {
        _ = await RcloneRCClient.shared.setQueueExpiry(expiry: -3600)
        if let idx = spoolItems.firstIndex(where: { $0.id == item.id }) {
            spoolItems[idx].status = .uploading
            spoolItems[idx].writeBackRemainingSec = 0
        }
    }

    public func tagAsRetake(item: SpoolItem) async {
        let retakesDir = RcloneDaemonSupervisor.shared.mountPoint.appendingPathComponent("_Retakes")
        try? FileManager.default.createDirectory(at: retakesDir, withIntermediateDirectories: true)
        let newURL = retakesDir.appendingPathComponent(item.filename)
        try? FileManager.default.moveItem(at: item.localCachePath, to: newURL)

        if let idx = spoolItems.firstIndex(where: { $0.id == item.id }) {
            spoolItems[idx].status = .retake
            spoolItems[idx].relativePath = "_Retakes/\(item.filename)"
            spoolItems[idx].localCachePath = newURL
        }
    }

    public func purgeLocally(item: SpoolItem) async {
        try? FileManager.default.removeItem(at: item.localCachePath)
        _ = await RcloneRCClient.shared.forgetFile(relativePath: item.relativePath)

        if let idx = spoolItems.firstIndex(where: { $0.id == item.id }) {
            spoolItems[idx].status = .purged
        }
    }

    public func flushQueueImmediately() async {
        _ = await RcloneRCClient.shared.setQueueExpiry(expiry: -3600)
    }

    // MARK: - 1.5s Live Telemetry & VFS Queue Poller

    public func startTelemetryPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self = self else { break }
                await self.pollOnce()
            }
        }
    }

    public func stopTelemetryPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func pollOnce() async {
        _ = checkAPFSFreeSpace(forBytes: 0)

        async let coreStatsTask = RcloneRCClient.shared.fetchCoreStats()
        async let vfsStatsTask = RcloneRCClient.shared.fetchVFSStats()
        async let queueItemsTask = RcloneRCClient.shared.fetchVFSQueue()

        let (coreStats, vfsStats, queueDTOs) = await (coreStatsTask, vfsStatsTask, queueItemsTask)

        if let core = coreStats {
            let mbps = max(0.0, core.speedBytesPerSec / (1024.0 * 1024.0))
            if abs(telemetry.uploadSpeedMBps - mbps) > 0.01 {
                telemetry.uploadSpeedMBps = mbps
            }
            if mbps > 0.01 || (bandwidthHistory.last?.speedMBps ?? 0.0) > 0.01 {
                bandwidthHistory.append(BandwidthSample(timestamp: Date(), speedMBps: mbps))
                if bandwidthHistory.count > 40 {
                    bandwidthHistory.removeFirst(bandwidthHistory.count - 40)
                }
            }
        }

        if let vfs = vfsStats {
            if telemetry.spoolUsedBytes != vfs.bytesUsed ||
               telemetry.activeUploads != vfs.uploadsInProgress ||
               telemetry.activeQueued != vfs.uploadsQueued {
                telemetry.spoolUsedBytes = vfs.bytesUsed
                telemetry.activeUploads = vfs.uploadsInProgress
                telemetry.activeQueued = vfs.uploadsQueued
            }
        }

        let newIndexCount = RAMTreeIndexer.shared.indexedNodes.count
        if telemetry.ramIndexCount != newIndexCount {
            telemetry.ramIndexCount = newIndexCount
        }

        // Reconcile rclone vfs/queue items with local spoolItems list
        let mount = RcloneDaemonSupervisor.shared.mountPoint
        for dto in queueDTOs {
            if let idx = spoolItems.firstIndex(where: { $0.relativePath == dto.name || $0.filename == (dto.name as NSString).lastPathComponent }) {
                spoolItems[idx].writeBackRemainingSec = max(0, Int(dto.expiry))
                if !telemetry.isOnline {
                    spoolItems[idx].status = .pausedOffline
                } else {
                    spoolItems[idx].status = dto.uploading ? .uploading : .staging
                }
            } else {
                let filename = (dto.name as NSString).lastPathComponent
                let newItem = SpoolItem(
                    filename: filename,
                    relativePath: dto.name,
                    sizeBytes: dto.size,
                    status: telemetry.isOnline ? (dto.uploading ? .uploading : .staging) : .pausedOffline,
                    writeBackRemainingSec: max(0, Int(dto.expiry)),
                    localCachePath: mount.appendingPathComponent(dto.name)
                )
                spoolItems.append(newItem)
            }
        }
    }

    private func startNetworkReachabilityMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = (path.status == .satisfied)
            Task { @MainActor in
                guard let self = self else { return }
                self.telemetry.isOnline = online
                for idx in self.spoolItems.indices {
                    if !online && (self.spoolItems[idx].status == .staging || self.spoolItems[idx].status == .uploading) {
                        self.spoolItems[idx].status = .pausedOffline
                    } else if online && self.spoolItems[idx].status == .pausedOffline {
                        self.spoolItems[idx].status = .staging
                    }
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "co.aisimple.zerodrive.netmonitor"))
    }

    private func computeSize(of url: URL) -> Int64 {
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 {
            return Int64(size)
        }
        var total: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                let s = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                total += Int64(s)
            }
        }
        return max(total, 1024 * 1024)
    }

    private func extractMediaDuration(for url: URL) async -> String? {
        let ext = url.pathExtension.lowercased()
        guard ["mov", "mp4", "m4v", "mkv", "wav", "mp3", "m4a"].contains(ext) else {
            return nil
        }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = Int(CMTimeGetSeconds(duration))
        guard seconds > 0 else { return nil }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
