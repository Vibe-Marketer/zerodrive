import Foundation
import AppKit
import Darwin

public enum AdvisorSourceMode: String, CaseIterable, Identifiable, Sendable {
    case localMac = "Search Your Mac"
    case cloudSources = "Search Your Cloud"

    public var id: String { rawValue }
}

public enum MovableFileKind: String, CaseIterable, Identifiable, Sendable {
    case videoAudio = "Videos & Audio"
    case installerArchive = "Installers & Archives"
    case designPhoto = "Design & Raw Media"
    case documentData = "Docs & Assets"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .videoAudio: return "film.stack"
        case .installerArchive: return "archivebox.fill"
        case .designPhoto: return "paintbrush.pointed.fill"
        case .documentData: return "doc.richtext.fill"
        }
    }
}

public enum StorageAdvisorCategory: String, CaseIterable, Identifiable, Sendable {
    case all = "All Movable"
    case smartPicks = "Smart Picks"
    case videosMedia = "Videos & Audio"
    case installers = "Installers & Archives"
    case docsData = "Docs & Assets"
    case cold = "Cold (>60 Days)"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .all: return "internaldrive.fill"
        case .smartPicks: return "sparkles"
        case .videosMedia: return "film.stack"
        case .installers: return "archivebox.fill"
        case .docsData: return "doc.richtext.fill"
        case .cold: return "snowflake"
        }
    }
}

public enum AdvisorTransferMode: String, Sendable {
    case moveAndReclaim
    case copyKeepLocal
}

public enum StorageBucketKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case movableUserFiles = "Movable to ZeroDrive"
    case devCachesAndTemp = "Dev Caches & Temp"
    case appDatabasesAndAgents = "App Databases & Recorders"
    case lockedSystemAndApps = "Locked macOS & Apps"

    public var id: String { rawValue }
}

public struct MeasuredStorageEntry: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let path: String
    public let scanTargetFolderPath: String?
    public let allocatedBytes: Int64
    public let bucket: StorageBucketKind
    public let note: String

    public init(
        id: String,
        label: String,
        path: String,
        scanTargetFolderPath: String? = nil,
        allocatedBytes: Int64,
        bucket: StorageBucketKind,
        note: String
    ) {
        self.id = id
        self.label = label
        self.path = path
        self.scanTargetFolderPath = scanTargetFolderPath
        self.allocatedBytes = allocatedBytes
        self.bucket = bucket
        self.note = note
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: allocatedBytes, countStyle: .file)
    }
}

public struct MacDiskBreakdown: Codable, Sendable, Equatable {
    public var volumeTotalBytes: Int64
    public var availableImportantBytes: Int64
    public var availableRawBytes: Int64
    public var purgeableBytes: Int64
    public var usedBytes: Int64
    public var movableBytes: Int64
    public var zeroDriveCacheBytes: Int64
    public var nonMovableProtectedBytes: Int64
    public var skippedUserBundlesBytes: Int64
    public var skippedUserBundlesCount: Int
    public var cloudGhostLogicalBytes: Int64
    public var cloudGhostCount: Int
    public var devCachesAndTempBytes: Int64
    public var appDatabasesAndAgentsBytes: Int64
    public var lockedSystemAndAppsBytes: Int64
    public var smallWorkspaceFilesBytes: Int64
    public var isDeepAuditComplete: Bool
    public var bucketEntries: [MeasuredStorageEntry]

    public init(
        volumeTotalBytes: Int64 = 0,
        availableImportantBytes: Int64 = 0,
        availableRawBytes: Int64 = 0,
        purgeableBytes: Int64 = 0,
        usedBytes: Int64 = 0,
        movableBytes: Int64 = 0,
        zeroDriveCacheBytes: Int64 = 0,
        nonMovableProtectedBytes: Int64 = 0,
        skippedUserBundlesBytes: Int64 = 0,
        skippedUserBundlesCount: Int = 0,
        cloudGhostLogicalBytes: Int64 = 0,
        cloudGhostCount: Int = 0,
        devCachesAndTempBytes: Int64 = 0,
        appDatabasesAndAgentsBytes: Int64 = 0,
        lockedSystemAndAppsBytes: Int64 = 0,
        smallWorkspaceFilesBytes: Int64 = 0,
        isDeepAuditComplete: Bool = false,
        bucketEntries: [MeasuredStorageEntry] = []
    ) {
        self.volumeTotalBytes = volumeTotalBytes
        self.availableImportantBytes = availableImportantBytes
        self.availableRawBytes = availableRawBytes
        self.purgeableBytes = purgeableBytes
        self.usedBytes = usedBytes
        self.movableBytes = movableBytes
        self.zeroDriveCacheBytes = zeroDriveCacheBytes
        self.nonMovableProtectedBytes = nonMovableProtectedBytes
        self.skippedUserBundlesBytes = skippedUserBundlesBytes
        self.skippedUserBundlesCount = skippedUserBundlesCount
        self.cloudGhostLogicalBytes = cloudGhostLogicalBytes
        self.cloudGhostCount = cloudGhostCount
        self.devCachesAndTempBytes = devCachesAndTempBytes
        self.appDatabasesAndAgentsBytes = appDatabasesAndAgentsBytes
        self.lockedSystemAndAppsBytes = lockedSystemAndAppsBytes
        self.smallWorkspaceFilesBytes = smallWorkspaceFilesBytes
        self.isDeepAuditComplete = isDeepAuditComplete
        self.bucketEntries = bucketEntries
    }
}

public struct FolderReclaimSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public let folderName: String
    public let folderPath: String
    public let fileCount: Int
    public let allocatedBytes: Int64

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: allocatedBytes, countStyle: .file)
    }
}

public struct StorageAdvisorItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let url: URL
    public let name: String
    public let path: String
    public let sourceFolder: String
    public let sourceFolderPath: String
    public let relativeSubpath: String
    public let displayLocationPath: String
    public let uploadRelativeSubpath: String
    public let sizeBytes: Int64
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let fileKind: MovableFileKind
    public let lastAccessedDate: Date
    public let modifiedDate: Date
    public let category: StorageAdvisorCategory
    public let isSmartPick: Bool
    public var isSelected: Bool

    public init(
        url: URL,
        sourceFolder: String = "",
        sourceFolderPath: String = "",
        relativeSubpath: String = "",
        displayLocationPath: String = "",
        uploadRelativeSubpath: String = "",
        sizeBytes: Int64,
        logicalBytes: Int64 = 0,
        allocatedBytes: Int64 = 0,
        fileKind: MovableFileKind = .documentData,
        lastAccessedDate: Date,
        modifiedDate: Date,
        category: StorageAdvisorCategory,
        isSmartPick: Bool = false,
        isSelected: Bool = true
    ) {
        self.id = url.path
        self.url = url
        self.name = url.lastPathComponent
        self.path = url.path
        let resolvedFolder = sourceFolder.isEmpty ? url.deletingLastPathComponent().lastPathComponent : sourceFolder
        self.sourceFolder = resolvedFolder
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if !sourceFolderPath.isEmpty {
            self.sourceFolderPath = sourceFolderPath
        } else if url.path.hasPrefix("/private/tmp/") {
            self.sourceFolderPath = "/private/tmp"
        } else {
            self.sourceFolderPath = homePath + "/" + resolvedFolder
        }
        let resolvedRel = relativeSubpath.isEmpty ? url.lastPathComponent : relativeSubpath
        self.relativeSubpath = resolvedRel
        if !displayLocationPath.isEmpty {
            self.displayLocationPath = displayLocationPath
        } else if url.path.hasPrefix(homePath + "/") {
            self.displayLocationPath = "~/\(String(url.path.dropFirst(homePath.count + 1)))"
        } else {
            self.displayLocationPath = url.path
        }
        if !uploadRelativeSubpath.isEmpty {
            self.uploadRelativeSubpath = uploadRelativeSubpath
        } else if url.path.hasPrefix("/private/tmp/") {
            self.uploadRelativeSubpath = "private-tmp/\(String(url.path.dropFirst("/private/tmp/".count)))"
        } else {
            self.uploadRelativeSubpath = resolvedRel
        }
        self.sizeBytes = sizeBytes
        self.logicalBytes = logicalBytes > 0 ? logicalBytes : sizeBytes
        self.allocatedBytes = allocatedBytes > 0 ? allocatedBytes : sizeBytes
        self.fileKind = fileKind
        self.lastAccessedDate = lastAccessedDate
        self.modifiedDate = modifiedDate
        self.category = category
        self.isSmartPick = isSmartPick
        self.isSelected = isSelected
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    public var formattedLastOpened: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: lastAccessedDate, relativeTo: Date())
    }

    public static func == (lhs: StorageAdvisorItem, rhs: StorageAdvisorItem) -> Bool {
        lhs.id == rhs.id
            && lhs.isSelected == rhs.isSelected
            && lhs.sizeBytes == rhs.sizeBytes
    }
}

public struct CloudProviderSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let icon: String
    public let isConnected: Bool
    public let itemCount: Int
    public let totalLogicalBytes: Int64

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalLogicalBytes, countStyle: .file)
    }
}

public struct CloudAdvisorItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let displayPath: String
    public let providerID: String
    public let providerLabel: String
    public let localStubURL: URL?
    public let rcloneRemoteSpec: String?
    public let logicalBytes: Int64
    public let allocatedLocalBytes: Int64
    public let modifiedDate: Date
    public let fileKind: MovableFileKind
    public let isPossibleDuplicate: Bool
    public var isSelected: Bool

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: logicalBytes, countStyle: .file)
    }

    public var formattedModified: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: modifiedDate, relativeTo: Date())
    }

    public static func == (lhs: CloudAdvisorItem, rhs: CloudAdvisorItem) -> Bool {
        lhs.id == rhs.id && lhs.isSelected == rhs.isSelected
    }
}

private struct LocalMacScanOutput: Sendable {
    let items: [StorageAdvisorItem]
    let folderSummaries: [FolderReclaimSummary]
    let breakdown: MacDiskBreakdown
    let devSkippedArtifactDirs: [String]
    let labSkippedArtifactDirs: [String]
    let otherSkippedArtifactDirs: [String]
}

private struct CloudScanOutput: Sendable {
    let items: [CloudAdvisorItem]
    let providers: [CloudProviderSummary]
}

@MainActor
public final class ManageStorageAdvisor: ObservableObject {
    public static let shared = ManageStorageAdvisor()

    @Published public var mode: AdvisorSourceMode = .localMac

    // Local Mac SSD State
    @Published public private(set) var isScanning: Bool = false
    @Published public private(set) var isAnalyzingSystemStorage: Bool = false
    @Published public private(set) var isReclaiming: Bool = false
    @Published public private(set) var scanProgress: Double = 0.0
    @Published public private(set) var statusMessage: String = "Ready to scan Mac SSD for real movable files"
    @Published public private(set) var items: [StorageAdvisorItem] = []
    @Published public private(set) var folderSummaries: [FolderReclaimSummary] = []
    @Published public private(set) var diskBreakdown: MacDiskBreakdown = MacDiskBreakdown()
    @Published public private(set) var totalReclaimableBytes: Int64 = 0
    @Published public private(set) var totalSpaceReclaimedLifetime: Int64 = 0
    @Published public private(set) var lastScanDate: Date? = nil
    @Published public var selectedFilter: StorageAdvisorCategory = .all
    @Published public var selectedFolderFilter: String? = nil
    @Published public var searchQuery: String = ""
    @Published public private(set) var customScanRootURL: URL? = nil

    // Cloud Discovery State
    @Published public private(set) var isCloudScanning: Bool = false
    @Published public private(set) var isCloudTransferring: Bool = false
    @Published public private(set) var cloudStatusMessage: String = "Search connected clouds or iCloud stubs without downloading to SSD"
    @Published public private(set) var cloudItems: [CloudAdvisorItem] = []
    @Published public private(set) var cloudProviders: [CloudProviderSummary] = []
    @Published public var selectedCloudProviderFilter: String? = nil
    @Published public var cloudSearchQuery: String = ""
    @Published public var hideDuplicateCloudItems: Bool = false
    @Published public var isConnectingProvider: String? = nil
    @Published public var skillInstallFeedback: String = ""

    private var activeRcloneProcess: Process? = nil
    private var cancelRequested: Bool = false
    private var deepAuditGeneration: Int = 0

    private var statsFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/rclone/storage-advisor-stats.json")
    }

    private nonisolated static var diskMapCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/rclone/storage-advisor-disk-map.json")
    }

    private init() {
        loadPersistedStats()
        loadCachedDiskMap()
        refreshVolumeBreakdownOnly()
    }

    private func loadPersistedStats() {
        guard let data = try? Data(contentsOf: statsFileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        totalSpaceReclaimedLifetime = (dict["totalSpaceReclaimedLifetime"] as? NSNumber)?.int64Value ?? 0
        if let ts = dict["lastScanDate"] as? TimeInterval {
            lastScanDate = Date(timeIntervalSince1970: ts)
        }
    }

    private func savePersistedStats() {
        let dict: [String: Any] = [
            "totalSpaceReclaimedLifetime": totalSpaceReclaimedLifetime,
            "lastScanDate": lastScanDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        ]
        let parent = statsFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? data.write(to: statsFileURL, options: .atomic)
        }
    }

    private func loadCachedDiskMap() {
        guard let data = try? Data(contentsOf: Self.diskMapCacheURL),
              let cached = try? JSONDecoder().decode(MacDiskBreakdown.self, from: data) else {
            return
        }
        self.diskBreakdown = cached
    }

    private nonisolated static func saveCachedDiskMap(_ breakdown: MacDiskBreakdown) {
        let url = diskMapCacheURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(breakdown) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Computed Filters (Local Mac)

    public var filteredItems: [StorageAdvisorItem] {
        let now = Date()
        let sixtyDaysAgo = now.addingTimeInterval(-60 * 24 * 3600)
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return items.filter { item in
            if let folder = selectedFolderFilter, item.sourceFolder != folder {
                return false
            }

            switch selectedFilter {
            case .all:
                break
            case .smartPicks:
                if !item.isSmartPick { return false }
            case .videosMedia:
                if item.fileKind != .videoAudio { return false }
            case .installers:
                if item.fileKind != .installerArchive { return false }
            case .docsData:
                if item.fileKind != .documentData && item.fileKind != .designPhoto { return false }
            case .cold:
                if item.lastAccessedDate >= sixtyDaysAgo { return false }
            }

            if !q.isEmpty {
                let matchesName = item.name.lowercased().contains(q)
                let matchesPath = item.relativeSubpath.lowercased().contains(q)
                let matchesKind = item.fileKind.rawValue.lowercased().contains(q)
                if !matchesName && !matchesPath && !matchesKind {
                    return false
                }
            }
            return true
        }
    }

    public var selectedBytes: Int64 {
        items.filter { $0.isSelected }.reduce(0) { $0 + $1.sizeBytes }
    }

    public var selectedCount: Int {
        items.filter { $0.isSelected }.count
    }

    public func toggleItemSelection(id: String) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].isSelected.toggle()
        }
    }

    public func selectAll(filterOnly: Bool = false) {
        if filterOnly {
            let visibleIDs = Set(filteredItems.map(\.id))
            for i in items.indices where visibleIDs.contains(items[i].id) {
                items[i].isSelected = true
            }
        } else {
            for i in items.indices {
                items[i].isSelected = true
            }
        }
    }

    public func deselectAll() {
        for i in items.indices {
            items[i].isSelected = false
        }
    }

    public func setCustomScanRoot(_ url: URL?) {
        customScanRootURL = url
        selectedFolderFilter = nil
        startScan()
    }

    // MARK: - Computed Filters (Cloud)

    public var filteredCloudItems: [CloudAdvisorItem] {
        let q = cloudSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cloudItems.filter { item in
            if let pid = selectedCloudProviderFilter, item.providerID != pid {
                return false
            }
            if hideDuplicateCloudItems && item.isPossibleDuplicate {
                return false
            }
            if !q.isEmpty {
                let matchesName = item.name.lowercased().contains(q)
                let matchesPath = item.displayPath.lowercased().contains(q)
                let matchesProvider = item.providerLabel.lowercased().contains(q)
                if !matchesName && !matchesPath && !matchesProvider {
                    return false
                }
            }
            return true
        }
    }

    public var selectedCloudBytes: Int64 {
        cloudItems.filter { $0.isSelected }.reduce(0) { $0 + $1.logicalBytes }
    }

    public var selectedCloudCount: Int {
        cloudItems.filter { $0.isSelected }.count
    }

    public var totalCloudLogicalBytes: Int64 {
        cloudItems.reduce(0) { $0 + $1.logicalBytes }
    }

    public var duplicateCloudCount: Int {
        cloudItems.filter { $0.isPossibleDuplicate }.count
    }

    public func toggleCloudItemSelection(id: String) {
        if let idx = cloudItems.firstIndex(where: { $0.id == id }) {
            cloudItems[idx].isSelected.toggle()
        }
    }

    public func selectAllCloud(excludeDuplicates: Bool = true) {
        let visibleIDs = Set(filteredCloudItems.map(\.id))
        for i in cloudItems.indices where visibleIDs.contains(cloudItems[i].id) {
            if excludeDuplicates && cloudItems[i].isPossibleDuplicate {
                continue
            }
            cloudItems[i].isSelected = true
        }
    }

    public func deselectAllCloud() {
        for i in cloudItems.indices {
            cloudItems[i].isSelected = false
        }
    }

    // MARK: - Local Mac SSD Scan (Zero-Symlink, Physical Blocks Only)

    public func refreshVolumeBreakdownOnly() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = Self.readVolumeMetrics(home: home)
        let prev = diskBreakdown
        let zdCache = Self.measureDirectoryAllocatedBytes(
            at: home.appendingPathComponent("Library/Caches/ZeroDrive").path,
            maxFiles: 25_000
        )
        let movable = items.isEmpty && prev.movableBytes > 0
            ? prev.movableBytes
            : items.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        let locked: Int64
        if prev.isDeepAuditComplete {
            let accounted = movable + prev.devCachesAndTempBytes + prev.appDatabasesAndAgentsBytes
            locked = prev.lockedSystemAndAppsBytes > 0
                ? prev.lockedSystemAndAppsBytes
                : max(0, base.usedBytes - accounted)
        } else {
            locked = max(0, base.usedBytes - movable - zdCache)
        }
        diskBreakdown = MacDiskBreakdown(
            volumeTotalBytes: base.totalBytes,
            availableImportantBytes: base.availableImportantBytes,
            availableRawBytes: base.availableRawBytes,
            purgeableBytes: base.purgeableBytes,
            usedBytes: base.usedBytes,
            movableBytes: movable,
            zeroDriveCacheBytes: zdCache,
            nonMovableProtectedBytes: locked,
            skippedUserBundlesBytes: prev.skippedUserBundlesBytes,
            skippedUserBundlesCount: prev.skippedUserBundlesCount,
            cloudGhostLogicalBytes: prev.cloudGhostLogicalBytes,
            cloudGhostCount: prev.cloudGhostCount,
            devCachesAndTempBytes: prev.devCachesAndTempBytes,
            appDatabasesAndAgentsBytes: prev.appDatabasesAndAgentsBytes,
            lockedSystemAndAppsBytes: prev.isDeepAuditComplete ? locked : prev.lockedSystemAndAppsBytes,
            smallWorkspaceFilesBytes: prev.smallWorkspaceFilesBytes,
            isDeepAuditComplete: prev.isDeepAuditComplete,
            bucketEntries: prev.bucketEntries
        )
    }

    public func startScan() {
        guard !isScanning && !isReclaiming else { return }

        isScanning = true
        scanProgress = 0.08
        statusMessage = "Scanning all Mac user folders & /private/tmp physical blocks…"

        let customRoot = customScanRootURL
        let home = FileManager.default.homeDirectoryForCurrentUser
        let prevBreakdown = self.diskBreakdown
        deepAuditGeneration += 1
        let generation = deepAuditGeneration

        Task {
            let output = await Task.detached(priority: .userInitiated) {
                Self.performLocalMacScan(home: home, customRoot: customRoot)
            }.value

            var mergedBreakdown = output.breakdown
            if customRoot == nil && prevBreakdown.isDeepAuditComplete {
                let accounted = output.breakdown.movableBytes + prevBreakdown.devCachesAndTempBytes + prevBreakdown.appDatabasesAndAgentsBytes
                let locked = prevBreakdown.lockedSystemAndAppsBytes > 0
                    ? prevBreakdown.lockedSystemAndAppsBytes
                    : max(0, output.breakdown.usedBytes - accounted)
                mergedBreakdown.devCachesAndTempBytes = prevBreakdown.devCachesAndTempBytes
                mergedBreakdown.appDatabasesAndAgentsBytes = prevBreakdown.appDatabasesAndAgentsBytes
                mergedBreakdown.lockedSystemAndAppsBytes = locked
                mergedBreakdown.nonMovableProtectedBytes = locked
                mergedBreakdown.isDeepAuditComplete = true
                mergedBreakdown.bucketEntries = prevBreakdown.bucketEntries
            }

            self.items = output.items
            self.folderSummaries = output.folderSummaries
            self.diskBreakdown = mergedBreakdown
            self.totalReclaimableBytes = output.breakdown.movableBytes
            self.lastScanDate = Date()
            self.savePersistedStats()
            self.isScanning = false
            self.scanProgress = 1.0

            let movableStr = ByteCountFormatter.string(fromByteCount: output.breakdown.movableBytes, countStyle: .file)
            if output.breakdown.cloudGhostCount > 0 {
                let ghostStr = ByteCountFormatter.string(fromByteCount: output.breakdown.cloudGhostLogicalBytes, countStyle: .file)
                self.statusMessage = "\(movableStr) real SSD movable (\(output.items.count) files) • Excluded \(ghostStr) in \(output.breakdown.cloudGhostCount) 0-byte cloud ghosts"
            } else {
                self.statusMessage = "Found \(output.items.count) movable SSD files • \(movableStr) reclaimable"
            }

            if customRoot == nil {
                self.isAnalyzingSystemStorage = true
                let phase1Breakdown = output.breakdown
                let devSkipped = output.devSkippedArtifactDirs
                let labSkipped = output.labSkippedArtifactDirs
                let otherSkipped = output.otherSkippedArtifactDirs

                let deepBreakdown = await Task.detached(priority: .utility) {
                    Self.performDeepSystemBreakdown(
                        home: home,
                        phase1Breakdown: phase1Breakdown,
                        devSkippedArtifactDirs: devSkipped,
                        labSkippedArtifactDirs: labSkipped,
                        otherSkippedArtifactDirs: otherSkipped
                    )
                }.value

                if self.deepAuditGeneration == generation && self.customScanRootURL == nil {
                    self.diskBreakdown = deepBreakdown
                    Self.saveCachedDiskMap(deepBreakdown)
                }
                self.isAnalyzingSystemStorage = false
            }
        }
    }

    // MARK: - Direct Cloud Transfer (Move & Reclaim or Copy)

    public func reclaimSelected(destinationSubfolder: String = "Cold Storage") async {
        await transferSelected(mode: .moveAndReclaim, destinationSubfolder: destinationSubfolder, preserveFolderStructure: true)
    }

    public func transferSelected(
        mode transferMode: AdvisorTransferMode,
        destinationSubfolder: String = "Cold Storage",
        preserveFolderStructure: Bool = true
    ) async {
        let targets = items.filter { $0.isSelected }
        guard !targets.isEmpty, !isReclaiming, !isScanning else { return }

        isReclaiming = true
        cancelRequested = false
        statusMessage = "Preparing \(transferMode == .moveAndReclaim ? "move" : "copy") for \(targets.count) Mac SSD files…"

        guard let rcloneURL = await RcloneDaemonSupervisor.shared.resolveOrDownloadRcloneBinary() else {
            isReclaiming = false
            statusMessage = "Streaming engine missing — download rclone in Settings first."
            return
        }

        let meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
        let configPath = MultiCloudCombineBuilder.shared.configPath.path
        let cleanDest = destinationSubfolder
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            .isEmpty ? "Cold Storage" : destinationSubfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))

        var bytesProcessed: Int64 = 0
        var completedIDs: Set<String> = []
        var failureCount = 0

        for (index, item) in targets.enumerated() {
            if cancelRequested { break }

            let sizeStr = item.formattedSize
            let verb = transferMode == .moveAndReclaim ? "Moving" : "Copying"
            statusMessage = "[\(index + 1)/\(targets.count)] \(verb) \(item.name) (\(sizeStr)) directly to ZeroDrive…"

            let relPath = preserveFolderStructure ? item.uploadRelativeSubpath : item.name
            let baseRemote = "primary_vault:\(meta.bucketAndPrefix)/\(cleanDest)/\(relPath)"

            let proc = Process()
            self.activeRcloneProcess = proc

            let result = await Task.detached(priority: .userInitiated) { () -> Bool in
                let targetRemote = Self.resolveCollisionRemotePath(
                    rcloneURL: rcloneURL,
                    configPath: configPath,
                    proposedRemotePath: baseRemote,
                    localLogicalSize: item.logicalBytes
                )

                // Check if exact same size already verified at targetRemote
                if let existingSize = Self.remoteFileSize(rcloneURL: rcloneURL, configPath: configPath, remotePath: targetRemote),
                   existingSize == item.logicalBytes {
                    return true
                }

                proc.executableURL = rcloneURL
                proc.arguments = [
                    "copyto",
                    item.path,
                    targetRemote,
                    "--config=\(configPath)",
                    "--s3-upload-cutoff=32M",
                    "--s3-chunk-size=16M",
                    "--s3-upload-concurrency=4",
                    "--disable-http2",
                    "--s3-disable-http2",
                    "--retries=3",
                    "--low-level-retries=8",
                    "--timeout=60s"
                ]
                proc.standardOutput = Pipe()
                proc.standardError = Pipe()

                do {
                    try proc.run()
                    proc.waitUntilExit()
                } catch {
                    return false
                }

                guard proc.terminationStatus == 0 else { return false }

                guard let verifiedSize = Self.remoteFileSize(rcloneURL: rcloneURL, configPath: configPath, remotePath: targetRemote) else {
                    return false
                }
                return verifiedSize == item.logicalBytes
            }.value

            self.activeRcloneProcess = nil

            if result {
                if transferMode == .moveAndReclaim {
                    do {
                        try FileManager.default.removeItem(at: item.url)
                        bytesProcessed += item.allocatedBytes
                        totalSpaceReclaimedLifetime += item.allocatedBytes
                        completedIDs.insert(item.id)
                    } catch {
                        failureCount += 1
                        NSLog("[StorageAdvisor] Verified in cloud but failed to remove local %@: %@", item.path, error.localizedDescription)
                    }
                } else {
                    bytesProcessed += item.allocatedBytes
                    completedIDs.insert(item.id)
                }
            } else {
                failureCount += 1
            }
        }

        if transferMode == .moveAndReclaim {
            items.removeAll { completedIDs.contains($0.id) }
            totalReclaimableBytes = items.reduce(0) { $0 + $1.allocatedBytes }
            folderSummaries = Self.computeFolderSummaries(from: items)
            refreshVolumeBreakdownOnly()
            savePersistedStats()
        } else {
            for idx in items.indices where completedIDs.contains(items[idx].id) {
                items[idx].isSelected = false
            }
        }

        isReclaiming = false
        activeRcloneProcess = nil

        let formattedDone = ByteCountFormatter.string(fromByteCount: bytesProcessed, countStyle: .file)
        if cancelRequested {
            statusMessage = "Transfer stopped • \(formattedDone) completed before stop"
        } else if transferMode == .moveAndReclaim {
            statusMessage = failureCount == 0
                ? "Reclaimed \(formattedDone) of real Mac SSD space!"
                : "Reclaimed \(formattedDone) (\(failureCount) item(s) could not be moved)"
        } else {
            statusMessage = failureCount == 0
                ? "Copied \(formattedDone) safely to ZeroDrive (local files kept)"
                : "Copied \(formattedDone) (\(failureCount) item(s) failed)"
        }

        _ = await RcloneRCClient.shared.refreshVFSTree()
        await VaultStats.shared.refresh(rclone: rcloneURL, forceFullSize: false)
    }

    public func cancelTransfer() {
        cancelRequested = true
        if let proc = activeRcloneProcess, proc.isRunning {
            proc.terminate()
        }
        activeRcloneProcess = nil
    }

    // MARK: - Cloud Discovery & Cloud-to-ZeroDrive Workflows

    public func startCloudScan() {
        guard !isCloudScanning else { return }
        isCloudScanning = true
        cloudStatusMessage = "Scanning iCloud stubs & connected cloud drives (0 bytes downloaded)…"

        let home = FileManager.default.homeDirectoryForCurrentUser
        let rcloneURL = RcloneDaemonSupervisor.shared.resolveRcloneBinary()
        let connectedOAuth = MultiCloudCombineBuilder.shared.connectedExternalClouds()
        let configPath = MultiCloudCombineBuilder.shared.configPath.path

        Task {
            let output = await Task.detached(priority: .userInitiated) {
                Self.performCloudScan(
                    home: home,
                    rcloneURL: rcloneURL,
                    connectedOAuth: connectedOAuth,
                    configPath: configPath
                )
            }.value

            self.cloudItems = output.items
            self.cloudProviders = output.providers
            self.isCloudScanning = false

            let totalStr = ByteCountFormatter.string(fromByteCount: output.items.reduce(0) { $0 + $1.logicalBytes }, countStyle: .file)
            let dupCount = output.items.filter { $0.isPossibleDuplicate }.count
            if dupCount > 0 {
                self.cloudStatusMessage = "Found \(output.items.count) cloud items (\(totalStr)) • \(dupCount) possible sibling duplicates unchecked"
            } else {
                self.cloudStatusMessage = "Found \(output.items.count) cloud items (\(totalStr)) ready to copy or move"
            }
        }
    }

    public func connectExternalCloud(_ provider: ExternalCloudProvider) async {
        guard isConnectingProvider == nil else { return }
        isConnectingProvider = provider.rawValue
        cloudStatusMessage = "Opening \(provider.displayName) sign-in…"

        guard let rcloneURL = await RcloneDaemonSupervisor.shared.resolveOrDownloadRcloneBinary() else {
            isConnectingProvider = nil
            cloudStatusMessage = "rclone engine missing — install engine in Settings first."
            return
        }

        let (ok, msg) = await MultiCloudCombineBuilder.shared.connectExternalCloudOAuth(provider: provider, rcloneURL: rcloneURL)
        isConnectingProvider = nil
        if ok {
            cloudStatusMessage = "Connected \(provider.displayName)! Scanning available cloud files…"
            startCloudScan()
        } else {
            cloudStatusMessage = "Could not connect \(provider.displayName): \(msg)"
        }
    }

    public func launchDirectICloudStream() {
        cloudStatusMessage = "Launching Direct iCloud RAM Streamer…"
        Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = ["/Users/Naegele/_LAB/zerodrive/stream-icloud-to-vault.py", "Desktop/MAIN", "MAIN"]
            try? proc.run()
        }
    }

    public func transferCloudSelected(isCopy: Bool, destinationSubfolder: String = "Cloud Imports") async {
        let selected = cloudItems.filter { $0.isSelected }
        guard !selected.isEmpty, !isCloudTransferring else { return }

        isCloudTransferring = true
        let cleanDest = destinationSubfolder
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            .isEmpty ? "Cloud Imports" : destinationSubfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))

        let remoteItems = selected.filter { $0.rcloneRemoteSpec != nil }
        let localStubURLs = selected.compactMap { $0.localStubURL }

        if !localStubURLs.isEmpty {
            TurboMigrationManager.shared.startTransfer(
                urls: localStubURLs,
                destinationSubfolder: cleanDest,
                isCopy: isCopy,
                leaveSymlink: false
            )
        }

        if !remoteItems.isEmpty, let rcloneURL = await RcloneDaemonSupervisor.shared.resolveOrDownloadRcloneBinary() {
            let meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
            let configPath = MultiCloudCombineBuilder.shared.configPath.path
            let cmd = isCopy ? "copyto" : "moveto"

            for (idx, item) in remoteItems.enumerated() {
                guard let srcSpec = item.rcloneRemoteSpec else { continue }
                cloudStatusMessage = "[\(idx + 1)/\(remoteItems.count)] Streaming \(item.name) to ZeroDrive…"
                let dstSpec = "primary_vault:\(meta.bucketAndPrefix)/\(cleanDest)/\(item.name)"

                _ = await Task.detached(priority: .userInitiated) { () -> Bool in
                    let proc = Process()
                    proc.executableURL = rcloneURL
                    proc.arguments = [
                        cmd,
                        srcSpec,
                        dstSpec,
                        "--config=\(configPath)",
                        "--s3-upload-cutoff=32M",
                        "--s3-chunk-size=16M",
                        "--disable-http2",
                        "--s3-disable-http2",
                        "--retries=3"
                    ]
                    proc.standardOutput = Pipe()
                    proc.standardError = Pipe()
                    try? proc.run()
                    proc.waitUntilExit()
                    return proc.terminationStatus == 0
                }.value
            }
            _ = await RcloneRCClient.shared.refreshVFSTree()
        }

        isCloudTransferring = false
        if !localStubURLs.isEmpty {
            cloudStatusMessage = "Started governed \(isCopy ? "copy" : "move") for \(localStubURLs.count) cloud stub(s) in Activity."
        } else {
            cloudStatusMessage = "Completed direct cloud-to-ZeroDrive \(isCopy ? "copy" : "move") for \(remoteItems.count) item(s)."
        }
    }

    public func installOrganizeSkillToAgents() -> String {
        let bundledSkillDir = Bundle.main.resourceURL?.appendingPathComponent("_SKILLS/organize-cloud-files").path
        let repoSkillDir = "/Users/Naegele/_LAB/zerodrive/_SKILLS/organize-cloud-files"
        let sourceSkillDir: String
        if let bundled = bundledSkillDir, FileManager.default.fileExists(atPath: bundled) {
            sourceSkillDir = bundled
        } else {
            sourceSkillDir = repoSkillDir
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let targets = [
            home.appendingPathComponent(".claude/skills"),
            home.appendingPathComponent(".codex/skills"),
            home.appendingPathComponent(".agents/skills")
        ]

        var linkedCount = 0
        for parent in targets {
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let dest = parent.appendingPathComponent("organize-cloud-files")
            if FileManager.default.fileExists(atPath: dest.path) {
                linkedCount += 1
                continue
            }
            do {
                try FileManager.default.createSymbolicLink(atPath: dest.path, withDestinationPath: sourceSkillDir)
                linkedCount += 1
            } catch {
                NSLog("[StorageAdvisor] Skill link failed for %@: %@", dest.path, error.localizedDescription)
            }
        }

        let msg = "Skill installed to \(linkedCount)/3 agent directories (~/.claude, ~/.codex, ~/.agents)."
        skillInstallFeedback = msg
        return msg
    }

    public func generateAgentOrganizePrompt(destinationSubfolder: String) -> String {
        let selected = cloudItems.filter { $0.isSelected }
        let sampleItems = (selected.isEmpty ? Array(cloudItems.prefix(8)) : Array(selected.prefix(12)))
        let lines = sampleItems.map { item in
            let dup = item.isPossibleDuplicate ? " [possible duplicate]" : ""
            return "- \(item.displayPath) (\(item.formattedSize), \(item.providerLabel))\(dup)"
        }.joined(separator: "\n")

        let cleanDest = destinationSubfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let targetDest = cleanDest.isEmpty ? "Cloud Imports" : cleanDest

        return """
        Use the `organize-cloud-files` skill at `/Users/Naegele/_LAB/zerodrive/_SKILLS/organize-cloud-files/SKILL.md`.
        Inspect these cloud files without hydrating stubs onto my Mac SSD, flag any exact-size duplicates, propose a clean folder structure inside `My Drive/\(targetDest)`, and copy/organize them into ZeroDrive after I confirm:

        \(lines.isEmpty ? "- (Scan iCloud Drive / CloudStorage folders first)" : lines)
        """
    }

    // MARK: - Nonisolated Fast POSIX Mac Scanner

    private nonisolated static let sfDatalessFlag: UInt32 = 0x40000000

    private nonisolated static let excludedTopLevelFolders: Set<String> = [
        "Library", "Applications", "Public", "ZeroDrive", ".zerodrive"
    ]

    private nonisolated static let excludedDirNames: Set<String> = [
        "node_modules", ".git", ".hg", ".svn", ".build", "build", "DerivedData",
        "venv", ".venv", "__pycache__", ".next", ".nuxt", "target", "Pods",
        "dist", "vendor", ".gradle", ".cargo", ".Trash", ".cache", ".npm", ".bun",
        "site-packages", ".tox", ".pytest_cache", ".mypy_cache", ".ruff_cache",
        ".turbo", ".parcel-cache", ".svelte-kit", "coverage", ".output",
        ".vercel", ".wrangler", ".rush", ".yarn", ".pnpm-store",
        "bower_components", "jspm_packages"
    ]

    private nonisolated static let excludedBundleExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "appex", "xcodeproj", "xcworkspace",
        "playground", "photoslibrary", "aplibrary", "musiclibrary", "tvlibrary",
        "fcpbundle", "imovielibrary", "logicx", "band", "abbu", "sparsebundle",
        "vmwarevm", "parallels", "utm", "git"
    ]

    private nonisolated static let blockedSystemExtensions: Set<String> = [
        "dylib", "so", "a", "o", "swiftmodule", "nib", "car", "icns",
        "lock", "wal", "shm", "db-wal", "db-shm", "sqlite-wal", "sqlite-shm",
        "vmdk", "qcow2", "sock", "pid"
    ]

    private nonisolated static let tmpSkipPrefixes: [String] = [
        "claude-", "com.apple.", "powerlog", "tmux-", "v8-", "npm-", "bun-",
        "pyright-", "cursor-", "antigravity-", "zed-", "playwright", "puppeteer"
    ]

    private nonisolated static let appleAppSupportSkip: Set<String> = [
        "AddressBook", "CallHistoryDB", "CallHistoryTransactions", "CloudDocs",
        "MobileSync", "FileProvider", "Knowledge", "DifferentialPrivacy",
        "FaceTime", "CrashReporter", "SyncServices", "Dock",
        "iLifeMediaBrowser", "CoreData", "DiskImages", "Apple"
    ]

    private nonisolated static func isExcludedBuildOrEnvDir(_ name: String) -> Bool {
        if excludedDirNames.contains(name) { return true }
        if name.hasPrefix(".venv") || name.hasPrefix("venv-") || name.hasPrefix("cmake-build-") { return true }
        if name.hasPrefix(".") && name != ".AGENT-IDE" { return true }
        return false
    }

    private nonisolated static func shouldSkipTmpSubdir(_ name: String) -> Bool {
        for prefix in tmpSkipPrefixes where name.hasPrefix(prefix) {
            return true
        }
        return false
    }

    private nonisolated static func classifyKind(ext: String) -> MovableFileKind {
        let lower = ext.lowercased()
        let videoAudioExts: Set<String> = [
            "mp4", "mov", "m4v", "mkv", "avi", "webm", "mpg", "mpeg",
            "mts", "m2ts", "prores", "wav", "mp3", "m4a", "aac", "flac", "aiff", "ogg"
        ]
        if videoAudioExts.contains(lower) { return .videoAudio }

        let archiveExts: Set<String> = [
            "dmg", "pkg", "iso", "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz", "zst"
        ]
        if archiveExts.contains(lower) { return .installerArchive }

        let designPhotoExts: Set<String> = [
            "psd", "psb", "ai", "eps", "indd", "fig", "sketch", "xd", "blend",
            "c4d", "prproj", "aep", "png", "jpg", "jpeg", "heic", "webp",
            "tif", "tiff", "bmp", "dng", "cr2", "cr3", "nef", "arw", "raf"
        ]
        if designPhotoExts.contains(lower) { return .designPhoto }

        return .documentData
    }

    private nonisolated static func readVolumeMetrics(home: URL) -> (
        totalBytes: Int64,
        availableImportantBytes: Int64,
        availableRawBytes: Int64,
        purgeableBytes: Int64,
        usedBytes: Int64
    ) {
        let vals = try? home.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])
        let total = Int64(vals?.volumeTotalCapacity ?? 0)
        let raw = Int64(vals?.volumeAvailableCapacity ?? 0)
        let imp = vals?.volumeAvailableCapacityForImportantUsage ?? raw
        let purgeable = max(0, imp - raw)
        let used = max(0, total - imp)
        return (total, imp, raw, purgeable, used)
    }

    private nonisolated static func direntName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &entry.pointee.d_name) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { cStr in
                String(cString: cStr)
            }
        }
    }

    private nonisolated static func measureDirectoryAllocatedBytes(at path: String, maxFiles: Int) -> Int64 {
        var rootStat = stat()
        guard Darwin.lstat(path, &rootStat) == 0 else { return 0 }
        if (rootStat.st_mode & S_IFMT) == S_IFLNK { return 0 }

        var total: Int64 = 0
        var visited = 0
        var stack: [String] = [path]

        while let current = stack.popLast() {
            if visited >= maxFiles { break }
            guard let dir = opendir(current) else { continue }
            defer { closedir(dir) }

            while let entry = readdir(dir) {
                if visited >= maxFiles { break }
                if Int32(entry.pointee.d_type) == DT_LNK { continue }
                let name = direntName(entry)
                if name == "." || name == ".." { continue }
                visited += 1

                let fullPath = current + "/" + name
                var st = stat()
                guard Darwin.lstat(fullPath, &st) == 0 else { continue }
                let fType = st.st_mode & S_IFMT
                if fType == S_IFLNK { continue }
                if fType == S_IFDIR {
                    stack.append(fullPath)
                } else if fType == S_IFREG {
                    if (st.st_flags & sfDatalessFlag) == 0 {
                        total += Int64(st.st_blocks) * 512
                    }
                }
            }
        }
        return total
    }

    private struct ScanWorkUnit: Sendable {
        let rootLabel: String
        let rootPath: String
        let unitPath: String
        let rootFilesOnly: Bool
    }

    private struct RootScanResult: Sendable {
        let label: String
        let path: String
        var items: [StorageAdvisorItem] = []
        var cloudGhostLogical: Int64 = 0
        var cloudGhostCount: Int = 0
        var skippedBundlesBytes: Int64 = 0
        var skippedBundlesCount: Int = 0
        var movableBytes: Int64 = 0
        var smallFilesBytes: Int64 = 0
        var skippedArtifactDirs: [String] = []
    }

    private final class LockedRootResults: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [RootScanResult] = []

        func append(_ res: RootScanResult) {
            lock.lock()
            storage.append(res)
            lock.unlock()
        }

        func snapshot() -> [RootScanResult] {
            lock.lock()
            let copy = storage
            lock.unlock()
            return copy
        }
    }

    private nonisolated static func performLocalMacScan(home: URL, customRoot: URL?) -> LocalMacScanOutput {
        let vol = readVolumeMetrics(home: home)
        let zdCacheBytes = measureDirectoryAllocatedBytes(
            at: home.appendingPathComponent("Library/Caches/ZeroDrive").path,
            maxFiles: 30_000
        )

        var homeStat = stat()
        guard Darwin.lstat(home.path, &homeStat) == 0 else {
            return LocalMacScanOutput(
                items: [],
                folderSummaries: [],
                breakdown: MacDiskBreakdown(
                    volumeTotalBytes: vol.totalBytes,
                    availableImportantBytes: vol.availableImportantBytes,
                    availableRawBytes: vol.availableRawBytes,
                    purgeableBytes: vol.purgeableBytes,
                    usedBytes: vol.usedBytes,
                    zeroDriveCacheBytes: zdCacheBytes,
                    nonMovableProtectedBytes: max(0, vol.usedBytes - zdCacheBytes)
                ),
                devSkippedArtifactDirs: [],
                labSkippedArtifactDirs: [],
                otherSkippedArtifactDirs: []
            )
        }

        let homeDev = Int32(homeStat.st_dev)
        let currentUID = getuid()
        let homePath = home.path
        let now = Date()
        let tmpSettledCutoff = now.addingTimeInterval(-900)
        let sixtyDaysAgo = now.addingTimeInterval(-60 * 24 * 3600)
        let ninetyDaysAgo = now.addingTimeInterval(-90 * 24 * 3600)
        let fourteenDaysAgo = now.addingTimeInterval(-14 * 24 * 3600)
        let minMovableBytes: Int64 = 5 * 1024 * 1024

        var topRoots: [(label: String, path: String)] = []
        if let custom = customRoot {
            topRoots.append((custom.lastPathComponent, custom.path))
        } else {
            if let homeDir = opendir(homePath) {
                defer { closedir(homeDir) }
                while let entry = readdir(homeDir) {
                    if Int32(entry.pointee.d_type) == DT_LNK { continue }
                    let name = direntName(entry)
                    if name.hasPrefix(".") || excludedTopLevelFolders.contains(name) { continue }
                    let fullPath = homePath + "/" + name
                    var st = stat()
                    guard Darwin.lstat(fullPath, &st) == 0 else { continue }
                    if (st.st_mode & S_IFMT) != S_IFDIR || Int32(st.st_dev) != homeDev { continue }
                    let ext = (name as NSString).pathExtension.lowercased()
                    if excludedBundleExtensions.contains(ext) { continue }
                    topRoots.append((name, fullPath))
                }
            }
            var tmpStat = stat()
            if Darwin.lstat("/private/tmp", &tmpStat) == 0,
               (tmpStat.st_mode & S_IFMT) == S_IFDIR,
               Int32(tmpStat.st_dev) == homeDev {
                topRoots.append(("Temp (/private/tmp)", "/private/tmp"))
            }
        }

        // Shard large workspace roots 1 level deep so all cores scan _DEV/_LAB concurrently
        var workUnits: [ScanWorkUnit] = []
        var initialDevSkipped: [String] = []
        var initialLabSkipped: [String] = []
        var initialOtherSkipped: [String] = []
        let shardedRoots: Set<String> = ["_DEV", "_LAB", "gsd-workspaces"]

        for root in topRoots {
            if customRoot == nil && shardedRoots.contains(root.label) {
                workUnits.append(ScanWorkUnit(rootLabel: root.label, rootPath: root.path, unitPath: root.path, rootFilesOnly: true))
                if let dir = opendir(root.path) {
                    while let entry = readdir(dir) {
                        if Int32(entry.pointee.d_type) == DT_LNK { continue }
                        let name = direntName(entry)
                        if name == "." || name == ".." { continue }
                        let full = root.path + "/" + name
                        var st = stat()
                        guard Darwin.lstat(full, &st) == 0 else { continue }
                        guard (st.st_mode & S_IFMT) == S_IFDIR, Int32(st.st_dev) == homeDev else { continue }

                        if isExcludedBuildOrEnvDir(name) {
                            if name != ".Trash" {
                                if root.label == "_DEV" { initialDevSkipped.append(full) }
                                else if root.label == "_LAB" { initialLabSkipped.append(full) }
                                else { initialOtherSkipped.append(full) }
                            }
                            continue
                        }
                        let ext = (name as NSString).pathExtension.lowercased()
                        if excludedBundleExtensions.contains(ext) {
                            if root.label == "_DEV" { initialDevSkipped.append(full) }
                            else if root.label == "_LAB" { initialLabSkipped.append(full) }
                            else { initialOtherSkipped.append(full) }
                            continue
                        }
                        workUnits.append(ScanWorkUnit(rootLabel: root.label, rootPath: root.path, unitPath: full, rootFilesOnly: false))
                    }
                    closedir(dir)
                }
            } else {
                workUnits.append(ScanWorkUnit(rootLabel: root.label, rootPath: root.path, unitPath: root.path, rootFilesOnly: false))
            }
        }

        let collector = LockedRootResults()

        DispatchQueue.concurrentPerform(iterations: workUnits.count) { idx in
            let unit = workUnits[idx]
            let isPrivateTmp = (unit.rootPath == "/private/tmp")
            let isICloudSyncedRoot = (unit.rootLabel == "Desktop" || unit.rootLabel == "Documents")
            let isTrackedWorkspace = shardedRoots.contains(unit.rootLabel)
            var res = RootScanResult(label: unit.rootLabel, path: unit.rootPath)
            var stack: [String] = [unit.unitPath]

            let bufSize = 64 * 1024
            let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
            defer { buf.deallocate() }

            var al = attrlist()
            al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            al.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
                | attrgroup_t(ATTR_CMN_NAME)
                | attrgroup_t(ATTR_CMN_DEVID)
                | attrgroup_t(ATTR_CMN_OBJTYPE)
                | attrgroup_t(ATTR_CMN_OWNERID)
                | attrgroup_t(ATTR_CMN_FLAGS)
            al.fileattr = attrgroup_t(ATTR_FILE_TOTALSIZE) | attrgroup_t(ATTR_FILE_ALLOCSIZE)

            while let currentDir = stack.popLast() {
                let fd = Darwin.open(currentDir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if fd < 0 { continue }
                defer { Darwin.close(fd) }

                var checkedDirWritable = false
                var cachedDirWritable = true

                while true {
                    let count = getattrlistbulk(fd, &al, buf, bufSize, 0)
                    if count <= 0 { break }

                    var ptr = buf
                    for _ in 0..<count {
                        let len = Int(ptr.loadUnaligned(as: UInt32.self))
                        let next = ptr.advanced(by: len)
                        var curPtr = ptr.advanced(by: 4)

                        let ret = curPtr.loadUnaligned(as: attribute_set_t.self)
                        curPtr = curPtr.advanced(by: MemoryLayout<attribute_set_t>.size)

                        var name = ""
                        if (ret.commonattr & attrgroup_t(ATTR_CMN_NAME)) != 0 {
                            let ref = curPtr.loadUnaligned(as: attrreference_t.self)
                            name = String(cString: curPtr.advanced(by: Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                            curPtr = curPtr.advanced(by: MemoryLayout<attrreference_t>.size)
                        }

                        var dev: Int32 = homeDev
                        if (ret.commonattr & attrgroup_t(ATTR_CMN_DEVID)) != 0 {
                            dev = curPtr.loadUnaligned(as: Int32.self)
                            curPtr = curPtr.advanced(by: 4)
                        }

                        var objType: UInt32 = 0
                        if (ret.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE)) != 0 {
                            objType = curPtr.loadUnaligned(as: UInt32.self)
                            curPtr = curPtr.advanced(by: 4)
                        }

                        var owner: UInt32 = currentUID
                        if (ret.commonattr & attrgroup_t(ATTR_CMN_OWNERID)) != 0 {
                            owner = curPtr.loadUnaligned(as: UInt32.self)
                            curPtr = curPtr.advanced(by: 4)
                        }

                        var flags: UInt32 = 0
                        if (ret.commonattr & attrgroup_t(ATTR_CMN_FLAGS)) != 0 {
                            flags = curPtr.loadUnaligned(as: UInt32.self)
                            curPtr = curPtr.advanced(by: 4)
                        }

                        if name.isEmpty || name == "." || name == ".." || dev != homeDev {
                            ptr = next
                            continue
                        }

                        if objType == UInt32(VDIR.rawValue) {
                            if unit.rootFilesOnly {
                                ptr = next
                                continue
                            }
                            if isExcludedBuildOrEnvDir(name) {
                                if !isPrivateTmp && name != ".Trash" {
                                    res.skippedArtifactDirs.append(currentDir + "/" + name)
                                }
                                ptr = next
                                continue
                            }
                            if isPrivateTmp {
                                if shouldSkipTmpSubdir(name) || owner != currentUID {
                                    ptr = next
                                    continue
                                }
                            }
                            let ext = (name as NSString).pathExtension.lowercased()
                            if excludedBundleExtensions.contains(ext) {
                                res.skippedBundlesCount += 1
                                if !isPrivateTmp && isTrackedWorkspace {
                                    res.skippedArtifactDirs.append(currentDir + "/" + name)
                                }
                                ptr = next
                                continue
                            }
                            stack.append(currentDir + "/" + name)
                        } else if objType == UInt32(VREG.rawValue) {
                            if name.hasPrefix(".") {
                                ptr = next
                                continue
                            }

                            var logical: Int64 = 0
                            if (ret.fileattr & attrgroup_t(ATTR_FILE_TOTALSIZE)) != 0 {
                                logical = curPtr.loadUnaligned(as: Int64.self)
                                curPtr = curPtr.advanced(by: 8)
                            }
                            var allocated: Int64 = 0
                            if (ret.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE)) != 0 {
                                allocated = curPtr.loadUnaligned(as: Int64.self)
                                curPtr = curPtr.advanced(by: 8)
                            }

                            let isDataless = (flags & sfDatalessFlag) != 0
                            if isDataless || (allocated == 0 && logical > 0) {
                                res.cloudGhostLogical += logical
                                res.cloudGhostCount += 1
                                ptr = next
                                continue
                            }

                            if isICloudSyncedRoot && logical > 1_048_576 && allocated < (logical / 2) {
                                res.cloudGhostLogical += logical
                                res.cloudGhostCount += 1
                                ptr = next
                                continue
                            }

                            if allocated < minMovableBytes {
                                if owner == currentUID {
                                    res.smallFilesBytes += allocated
                                }
                                ptr = next
                                continue
                            }

                            let ext = (name as NSString).pathExtension.lowercased()
                            if blockedSystemExtensions.contains(ext) {
                                res.skippedBundlesBytes += allocated
                                res.skippedBundlesCount += 1
                                ptr = next
                                continue
                            }

                            if owner != currentUID {
                                res.skippedBundlesBytes += allocated
                                res.skippedBundlesCount += 1
                                ptr = next
                                continue
                            }

                            if !checkedDirWritable {
                                cachedDirWritable = (Darwin.access(currentDir, W_OK) == 0)
                                checkedDirWritable = true
                            }
                            let fullPath = currentDir + "/" + name
                            if !cachedDirWritable || Darwin.access(fullPath, R_OK) != 0 {
                                res.skippedBundlesBytes += allocated
                                res.skippedBundlesCount += 1
                                ptr = next
                                continue
                            }

                            var st = stat()
                            guard Darwin.lstat(fullPath, &st) == 0 else {
                                ptr = next
                                continue
                            }
                            let accessDate = Date(timeIntervalSince1970: TimeInterval(st.st_atimespec.tv_sec))
                            let modDate = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))

                            if isPrivateTmp && modDate > tmpSettledCutoff {
                                ptr = next
                                continue
                            }

                            let fileKind = classifyKind(ext: ext)
                            let isSmartPick: Bool = {
                                if fileKind == .installerArchive && (accessDate < fourteenDaysAgo || modDate < fourteenDaysAgo) {
                                    return true
                                }
                                if allocated >= 250 * 1024 * 1024 { return true }
                                if accessDate < sixtyDaysAgo || modDate < ninetyDaysAgo { return true }
                                return false
                            }()

                            let category: StorageAdvisorCategory = {
                                if isSmartPick { return .smartPicks }
                                switch fileKind {
                                case .videoAudio: return .videosMedia
                                case .installerArchive: return .installers
                                case .designPhoto, .documentData:
                                    return accessDate < sixtyDaysAgo ? .cold : .docsData
                                }
                            }()

                            let innerPath: String = fullPath.hasPrefix(unit.rootPath + "/")
                                ? String(fullPath.dropFirst(unit.rootPath.count + 1))
                                : name
                            let relSubpath = "\(unit.rootLabel)/\(innerPath)"
                            let displayLoc: String = fullPath.hasPrefix(homePath + "/")
                                ? "~/\(String(fullPath.dropFirst(homePath.count + 1)))"
                                : fullPath
                            let uploadRel: String = isPrivateTmp
                                ? "private-tmp/\(innerPath)"
                                : relSubpath

                            res.movableBytes += allocated
                            res.items.append(StorageAdvisorItem(
                                url: URL(fileURLWithPath: fullPath),
                                sourceFolder: unit.rootLabel,
                                sourceFolderPath: unit.rootPath,
                                relativeSubpath: relSubpath,
                                displayLocationPath: displayLoc,
                                uploadRelativeSubpath: uploadRel,
                                sizeBytes: allocated,
                                logicalBytes: logical,
                                allocatedBytes: allocated,
                                fileKind: fileKind,
                                lastAccessedDate: accessDate,
                                modifiedDate: modDate,
                                category: category,
                                isSmartPick: isSmartPick,
                                isSelected: isSmartPick
                            ))
                        }

                        ptr = next
                    }
                }
            }

            collector.append(res)
        }

        let results = collector.snapshot()
        var foundItems: [StorageAdvisorItem] = []
        var cloudGhostLogical: Int64 = 0
        var cloudGhostCount = 0
        var skippedBundlesBytes: Int64 = 0
        var skippedBundlesCount = 0
        var smallWorkspaceBytes: Int64 = 0
        var devSkipped: [String] = initialDevSkipped
        var labSkipped: [String] = initialLabSkipped
        var otherSkipped: [String] = initialOtherSkipped

        for r in results {
            foundItems.append(contentsOf: r.items)
            cloudGhostLogical += r.cloudGhostLogical
            cloudGhostCount += r.cloudGhostCount
            skippedBundlesBytes += r.skippedBundlesBytes
            skippedBundlesCount += r.skippedBundlesCount
            if r.label != "Temp (/private/tmp)" {
                smallWorkspaceBytes += r.smallFilesBytes
            }
            if !r.skippedArtifactDirs.isEmpty {
                if r.label == "_DEV" {
                    devSkipped.append(contentsOf: r.skippedArtifactDirs)
                } else if r.label == "_LAB" {
                    labSkipped.append(contentsOf: r.skippedArtifactDirs)
                } else {
                    otherSkipped.append(contentsOf: r.skippedArtifactDirs)
                }
            }
        }

        if !foundItems.isEmpty && !foundItems.contains(where: { $0.isSelected }) {
            for i in foundItems.indices where foundItems[i].allocatedBytes >= 100 * 1024 * 1024 {
                foundItems[i].isSelected = true
            }
        }

        foundItems.sort { $0.allocatedBytes > $1.allocatedBytes }

        let totalMovable = foundItems.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        let lockedBytes = max(0, vol.usedBytes - totalMovable - zdCacheBytes)
        let summaries = computeFolderSummaries(from: foundItems)

        let breakdown = MacDiskBreakdown(
            volumeTotalBytes: vol.totalBytes,
            availableImportantBytes: vol.availableImportantBytes,
            availableRawBytes: vol.availableRawBytes,
            purgeableBytes: vol.purgeableBytes,
            usedBytes: vol.usedBytes,
            movableBytes: totalMovable,
            zeroDriveCacheBytes: zdCacheBytes,
            nonMovableProtectedBytes: lockedBytes,
            skippedUserBundlesBytes: skippedBundlesBytes,
            skippedUserBundlesCount: skippedBundlesCount,
            cloudGhostLogicalBytes: cloudGhostLogical,
            cloudGhostCount: cloudGhostCount,
            smallWorkspaceFilesBytes: smallWorkspaceBytes
        )

        return LocalMacScanOutput(
            items: foundItems,
            folderSummaries: summaries,
            breakdown: breakdown,
            devSkippedArtifactDirs: devSkipped,
            labSkippedArtifactDirs: labSkipped,
            otherSkippedArtifactDirs: otherSkipped
        )
    }

    // MARK: - Phase 2: Work-Stealing getattrlistbulk Deep Audit

    private struct BulkSizeJob {
        let id: String
        let label: String
        let displayPath: String
        let scanTargetFolderPath: String?
        let seeds: [String]
        let initialBytes: Int64
        let deduplicateHardLinks: Bool
        let bucket: StorageBucketKind
        let note: String
        let minReportBytes: Int64
        let aggregateUnderAppSupportOther: Bool
    }

    private final class ShardedInodeSet: @unchecked Sendable {
        private let locks = (0..<16).map { _ in NSLock() }
        private var sets = Array(repeating: Set<UInt64>(), count: 16)

        func insertIfNew(dev: Int32, fileID: UInt64) -> Bool {
            let key = (UInt64(UInt32(bitPattern: dev)) << 48) ^ fileID
            let shard = Int(fileID & 15)
            locks[shard].lock()
            let inserted = sets[shard].insert(key).inserted
            locks[shard].unlock()
            return inserted
        }
    }

    private final class WorkStealingPool: @unchecked Sendable {
        struct Item {
            let jobIndex: Int
            let path: String
            let seedDev: Int32
            let dedupHardLinks: Bool
        }

        private let cond = NSCondition()
        private var queue: [Item]
        private var activeWorkers: Int = 0

        init(initialItems: [Item]) {
            self.queue = initialItems.reversed()
        }

        var approximateQueueCount: Int {
            cond.lock()
            let c = queue.count
            cond.unlock()
            return c
        }

        func pop() -> Item? {
            cond.lock()
            while queue.isEmpty {
                if activeWorkers == 0 {
                    cond.broadcast()
                    cond.unlock()
                    return nil
                }
                cond.wait()
            }
            activeWorkers += 1
            let item = queue.removeLast()
            cond.unlock()
            return item
        }

        func pushBatch(_ items: [Item]) {
            guard !items.isEmpty else { return }
            cond.lock()
            queue.append(contentsOf: items)
            cond.broadcast()
            cond.unlock()
        }

        func finishItem() {
            cond.lock()
            activeWorkers -= 1
            if queue.isEmpty && activeWorkers == 0 {
                cond.broadcast()
            }
            cond.unlock()
        }
    }

    private nonisolated static func collectFilteredChildren(
        parentPath: String,
        includeDir: (String) -> Bool
    ) -> (dirs: [String], topLevelFileBytes: Int64) {
        var dirs: [String] = []
        var fileBytes: Int64 = 0
        guard let d = opendir(parentPath) else { return ([], 0) }
        defer { closedir(d) }

        while let entry = readdir(d) {
            if Int32(entry.pointee.d_type) == DT_LNK { continue }
            let name = direntName(entry)
            if name == "." || name == ".." { continue }
            let full = parentPath + "/" + name
            var st = stat()
            guard Darwin.lstat(full, &st) == 0 else { continue }
            let fType = st.st_mode & S_IFMT
            if fType == S_IFLNK { continue }
            if fType == S_IFDIR {
                if includeDir(name) {
                    dirs.append(full)
                }
            } else if fType == S_IFREG {
                if (st.st_flags & sfDatalessFlag) == 0 {
                    fileBytes += Int64(st.st_blocks) * 512
                }
            }
        }
        return (dirs, fileBytes)
    }

    private nonisolated static func bulkSizeJobs(_ jobs: [BulkSizeJob]) -> [Int64] {
        var totals = jobs.map { $0.initialBytes }
        var initialWork: [WorkStealingPool.Item] = []

        for (idx, job) in jobs.enumerated() {
            for seed in job.seeds {
                var st = stat()
                guard Darwin.lstat(seed, &st) == 0 else { continue }
                let fType = st.st_mode & S_IFMT
                if fType == S_IFLNK { continue }
                if fType == S_IFREG {
                    if (st.st_flags & sfDatalessFlag) == 0 {
                        totals[idx] += Int64(st.st_blocks) * 512
                    }
                } else if fType == S_IFDIR && (st.st_flags & sfDatalessFlag) == 0 {
                    initialWork.append(WorkStealingPool.Item(
                        jobIndex: idx,
                        path: seed,
                        seedDev: Int32(st.st_dev),
                        dedupHardLinks: job.deduplicateHardLinks
                    ))
                }
            }
        }

        if initialWork.isEmpty { return totals }

        let pool = WorkStealingPool(initialItems: initialWork)
        let inodeSet = ShardedInodeSet()
        let totalsLock = NSLock()
        let workerCount = 10

        DispatchQueue.concurrentPerform(iterations: workerCount) { _ in
            var localTotals = Array(repeating: Int64(0), count: jobs.count)
            let bufSize = 64 * 1024
            let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
            defer { buf.deallocate() }

            var al = attrlist()
            al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            al.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
                | attrgroup_t(ATTR_CMN_NAME)
                | attrgroup_t(ATTR_CMN_DEVID)
                | attrgroup_t(ATTR_CMN_OBJTYPE)
                | attrgroup_t(ATTR_CMN_FLAGS)
                | attrgroup_t(ATTR_CMN_FILEID)
            al.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)

            while let work = pool.pop() {
                var stack: [String] = [work.path]
                var jobSum: Int64 = 0

                while let cur = stack.popLast() {
                    let fd = Darwin.open(cur, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                    if fd < 0 { continue }
                    defer { Darwin.close(fd) }

                    while true {
                        let count = getattrlistbulk(fd, &al, buf, bufSize, 0)
                        if count <= 0 { break }

                        var ptr = buf
                        for _ in 0..<count {
                            let len = Int(ptr.loadUnaligned(as: UInt32.self))
                            let next = ptr.advanced(by: len)
                            var c = ptr.advanced(by: 4)

                            let ret = c.loadUnaligned(as: attribute_set_t.self)
                            c = c.advanced(by: MemoryLayout<attribute_set_t>.size)

                            var name = ""
                            if (ret.commonattr & attrgroup_t(ATTR_CMN_NAME)) != 0 {
                                let ref = c.loadUnaligned(as: attrreference_t.self)
                                name = String(cString: c.advanced(by: Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                                c = c.advanced(by: MemoryLayout<attrreference_t>.size)
                            }

                            var dev: Int32 = work.seedDev
                            if (ret.commonattr & attrgroup_t(ATTR_CMN_DEVID)) != 0 {
                                dev = c.loadUnaligned(as: Int32.self)
                                c = c.advanced(by: 4)
                            }

                            var objType: UInt32 = 0
                            if (ret.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE)) != 0 {
                                objType = c.loadUnaligned(as: UInt32.self)
                                c = c.advanced(by: 4)
                            }

                            var flags: UInt32 = 0
                            if (ret.commonattr & attrgroup_t(ATTR_CMN_FLAGS)) != 0 {
                                flags = c.loadUnaligned(as: UInt32.self)
                                c = c.advanced(by: 4)
                            }

                            var fileID: UInt64 = 0
                            if (ret.commonattr & attrgroup_t(ATTR_CMN_FILEID)) != 0 {
                                fileID = c.loadUnaligned(as: UInt64.self)
                                c = c.advanced(by: 8)
                            }

                            if name.isEmpty || name == "." || name == ".." || dev != work.seedDev {
                                ptr = next
                                continue
                            }

                            if objType == UInt32(VDIR.rawValue) {
                                if (flags & sfDatalessFlag) == 0 {
                                    stack.append(cur + "/" + name)
                                }
                            } else if objType == UInt32(VREG.rawValue) {
                                var linkCount: UInt32 = 1
                                if (ret.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT)) != 0 {
                                    linkCount = c.loadUnaligned(as: UInt32.self)
                                    c = c.advanced(by: 4)
                                }
                                var alloc: Int64 = 0
                                if (ret.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE)) != 0 {
                                    alloc = c.loadUnaligned(as: Int64.self)
                                    c = c.advanced(by: 8)
                                }
                                if alloc > 0 && (flags & sfDatalessFlag) == 0 {
                                    if work.dedupHardLinks && linkCount > 1 && fileID != 0 {
                                        if inodeSet.insertIfNew(dev: dev, fileID: fileID) {
                                            jobSum += alloc
                                        }
                                    } else {
                                        jobSum += alloc
                                    }
                                }
                            }
                            ptr = next
                        }
                    }

                    if stack.count >= 8 && pool.approximateQueueCount < 160 {
                        let splitAt = stack.count / 2
                        let stolen = stack[splitAt...].map {
                            WorkStealingPool.Item(
                                jobIndex: work.jobIndex,
                                path: $0,
                                seedDev: work.seedDev,
                                dedupHardLinks: work.dedupHardLinks
                            )
                        }
                        stack.removeSubrange(splitAt...)
                        pool.pushBatch(stolen)
                    }
                }

                localTotals[work.jobIndex] += jobSum
                pool.finishItem()
            }

            totalsLock.lock()
            for i in 0..<jobs.count {
                totals[i] += localTotals[i]
            }
            totalsLock.unlock()
        }

        return totals
    }

    private nonisolated static func readAPFSNonDataVolumes() -> (osAndSystemBytes: Int64, vmSwapBytes: Int64) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = ["apfs", "list", "-plist"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0,
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let containers = plist["Containers"] as? [[String: Any]] else {
                return (0, 0)
            }

            let targetContainer = containers.first(where: { container in
                let vols = container["Volumes"] as? [[String: Any]] ?? []
                return vols.contains { ($0["Roles"] as? [String] ?? []).contains("Data") }
            }) ?? containers.max(by: {
                (($0["CapacityCeiling"] as? NSNumber)?.int64Value ?? 0) < (($1["CapacityCeiling"] as? NSNumber)?.int64Value ?? 0)
            })

            guard let container = targetContainer,
                  let volumes = container["Volumes"] as? [[String: Any]] else {
                return (0, 0)
            }

            var osBytes: Int64 = 0
            var vmBytes: Int64 = 0
            for vol in volumes {
                let roles = vol["Roles"] as? [String] ?? []
                let used = (vol["CapacityInUse"] as? NSNumber)?.int64Value ?? 0
                if roles.contains("VM") {
                    vmBytes += used
                } else if roles.contains("System") || roles.contains("Preboot") || roles.contains("Recovery") || roles.contains("Update") {
                    osBytes += used
                }
            }
            return (osBytes, vmBytes)
        } catch {
            return (0, 0)
        }
    }

    private nonisolated static func performDeepSystemBreakdown(
        home: URL,
        phase1Breakdown: MacDiskBreakdown,
        devSkippedArtifactDirs: [String],
        labSkippedArtifactDirs: [String],
        otherSkippedArtifactDirs: [String]
    ) -> MacDiskBreakdown {
        let homePath = home.path
        let currentUID = getuid()
        let vol = readVolumeMetrics(home: home)

        // Start APFS volume inspection concurrently while building directory job list
        final class APFSBox: @unchecked Sendable {
            var res: (osAndSystemBytes: Int64, vmSwapBytes: Int64) = (0, 0)
        }
        let apfsBox = APFSBox()
        let apfsGroup = DispatchGroup()
        apfsGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            apfsBox.res = readAPFSNonDataVolumes()
            apfsGroup.leave()
        }

        var jobs: [BulkSizeJob] = []

        // 1. Skipped artifact/build trees discovered in Phase 1
        if !devSkippedArtifactDirs.isEmpty {
            jobs.append(BulkSizeJob(
                id: "dev_artifacts",
                label: "~/_DEV (node_modules, .git & build artifacts)",
                displayPath: homePath + "/_DEV",
                scanTargetFolderPath: nil,
                seeds: devSkippedArtifactDirs,
                initialBytes: 0,
                deduplicateHardLinks: true,
                bucket: .devCachesAndTemp,
                note: "Re-installable dependencies, git packfiles & compiled targets",
                minReportBytes: 100_000_000,
                aggregateUnderAppSupportOther: false
            ))
        }
        if !labSkippedArtifactDirs.isEmpty {
            jobs.append(BulkSizeJob(
                id: "lab_artifacts",
                label: "~/_LAB (node_modules, .git & build artifacts)",
                displayPath: homePath + "/_LAB",
                scanTargetFolderPath: nil,
                seeds: labSkippedArtifactDirs,
                initialBytes: 0,
                deduplicateHardLinks: true,
                bucket: .devCachesAndTemp,
                note: "Re-installable dependencies, git packfiles & build caches",
                minReportBytes: 100_000_000,
                aggregateUnderAppSupportOther: false
            ))
        }
        if !otherSkippedArtifactDirs.isEmpty {
            jobs.append(BulkSizeJob(
                id: "other_ws_artifacts",
                label: "Other Workspace Dependencies & Builds",
                displayPath: homePath,
                scanTargetFolderPath: nil,
                seeds: otherSkippedArtifactDirs,
                initialBytes: 0,
                deduplicateHardLinks: true,
                bucket: .devCachesAndTemp,
                note: "Re-installable node_modules, .git & venv across secondary folders",
                minReportBytes: 250_000_000,
                aggregateUnderAppSupportOther: false
            ))
        }

        // 2. /var/folders/.../X, /C, and $TMPDIR
        let tmpPath = NSTemporaryDirectory().hasSuffix("/")
            ? String(NSTemporaryDirectory().dropLast())
            : NSTemporaryDirectory()
        let userVarRoot = (tmpPath as NSString).deletingLastPathComponent
        let varXPath = userVarRoot + "/X"
        let varCPath = userVarRoot + "/C"

        if FileManager.default.fileExists(atPath: varXPath) {
            jobs.append(BulkSizeJob(
                id: "var_folders_x",
                label: "App Update Code-Sign Caches (/var/folders/.../X)",
                displayPath: varXPath,
                scanTargetFolderPath: nil,
                seeds: [varXPath],
                initialBytes: 0,
                deduplicateHardLinks: false,
                bucket: .devCachesAndTemp,
                note: "Purgeable macOS app update clones (Chrome, Aside, Zoom) — cleared on reboot",
                minReportBytes: 250_000_000,
                aggregateUnderAppSupportOther: false
            ))
        }
        if FileManager.default.fileExists(atPath: varCPath) {
            jobs.append(BulkSizeJob(
                id: "var_folders_c",
                label: "macOS User App Caches (/var/folders/.../C)",
                displayPath: varCPath,
                scanTargetFolderPath: nil,
                seeds: [varCPath],
                initialBytes: 0,
                deduplicateHardLinks: false,
                bucket: .devCachesAndTemp,
                note: "Per-user Darwin sandbox & font/shader caches",
                minReportBytes: 250_000_000,
                aggregateUnderAppSupportOther: false
            ))
        }
        jobs.append(BulkSizeJob(
            id: "user_tmpdir",
            label: "macOS User Temp ($TMPDIR)",
            displayPath: tmpPath,
            scanTargetFolderPath: nil,
            seeds: [tmpPath],
            initialBytes: 0,
            deduplicateHardLinks: false,
            bucket: .devCachesAndTemp,
            note: "Temporary render extraction & app scratch files",
            minReportBytes: 100_000_000,
            aggregateUnderAppSupportOther: false
        ))

        // 3. /private/tmp/claude-*
        var claudeTmpDirs: [String] = []
        if let d = opendir("/private/tmp") {
            while let e = readdir(d) {
                let name = direntName(e)
                guard name.hasPrefix("claude-") else { continue }
                let full = "/private/tmp/" + name
                var st = stat()
                if Darwin.lstat(full, &st) == 0, st.st_uid == currentUID, (st.st_mode & S_IFMT) == S_IFDIR {
                    claudeTmpDirs.append(full)
                }
            }
            closedir(d)
        }
        if !claudeTmpDirs.isEmpty {
            jobs.append(BulkSizeJob(
                id: "claude_tmp_logs",
                label: "Claude CLI Temp Logs (/private/tmp/claude-*)",
                displayPath: "/private/tmp",
                scanTargetFolderPath: nil,
                seeds: claudeTmpDirs,
                initialBytes: 0,
                deduplicateHardLinks: false,
                bucket: .devCachesAndTemp,
                note: "Ephemeral CLI worker task logs in /private/tmp",
                minReportBytes: 100_000_000,
                aggregateUnderAppSupportOther: false
            ))
        }

        // 4. ~/Library/Caches (non-Apple)
        let cachesPath = homePath + "/Library/Caches"
        let cacheFiltered = collectFilteredChildren(parentPath: cachesPath) { name in
            !name.hasPrefix(".") && !name.hasPrefix("com.apple.") && name != "CloudKit"
        }
        let zdStr = ByteCountFormatter.string(fromByteCount: phase1Breakdown.zeroDriveCacheBytes, countStyle: .file)
        jobs.append(BulkSizeJob(
            id: "user_lib_caches",
            label: "App & Dev Caches (~/Library/Caches)",
            displayPath: cachesPath,
            scanTargetFolderPath: nil,
            seeds: cacheFiltered.dirs,
            initialBytes: cacheFiltered.topLevelFileBytes,
            deduplicateHardLinks: false,
            bucket: .devCachesAndTemp,
            note: "Regenerable app caches (includes ZeroDrive cache: \(zdStr))",
            minReportBytes: 100_000_000,
            aggregateUnderAppSupportOther: false
        ))

        // 5. Dev & toolchain dot-folders + pnpm store
        let devToolTargets: [(id: String, label: String, relPath: String, dedup: Bool, note: String)] = [
            ("dot_local", "Toolchains & Local Binaries (~/.local)", ".local", false, "pipx, Playwright browsers, Mason & CLI tools"),
            ("dot_cache", "ML & Package Caches (~/.cache)", ".cache", false, "HuggingFace models, pip, uv & whisper caches"),
            ("dot_pyenv", "Python Environments (~/.pyenv)", ".pyenv", false, "Installed Python versions & virtualenvs"),
            ("lib_pnpm", "pnpm Global Store (~/Library/pnpm)", "Library/pnpm", true, "Content-addressable Node package store"),
            ("dot_npm_global", "Global NPM Packages (~/.npm-global)", ".npm-global", true, "Globally installed Node CLI packages"),
            ("dot_rustup", "Rust Toolchains (~/.rustup)", ".rustup", false, "Rust compiler & cross-compile targets"),
            ("dot_zd_cache", "Legacy ZeroDrive Cache (~/.zerodrive-cache)", ".zerodrive-cache", false, "Old offline ZeroDrive mount cache"),
            ("dot_rembg", "Background Removal Models (~/.rembg)", ".rembg", false, "Cached ONNX ML segmentation models"),
            ("dot_bun", "Bun Cache & Globals (~/.bun)", ".bun", true, "Bun runtime & package cache"),
            ("dot_npm", "NPM Cache (~/.npm)", ".npm", false, "Cached npm tarball downloads")
        ]
        for t in devToolTargets {
            let p = homePath + "/" + t.relPath
            if FileManager.default.fileExists(atPath: p) {
                jobs.append(BulkSizeJob(
                    id: t.id,
                    label: t.label,
                    displayPath: p,
                    scanTargetFolderPath: nil,
                    seeds: [p],
                    initialBytes: 0,
                    deduplicateHardLinks: t.dedup,
                    bucket: .devCachesAndTemp,
                    note: t.note,
                    minReportBytes: 250_000_000,
                    aggregateUnderAppSupportOther: false
                ))
            }
        }

        // 6. Heavy capture recorders, Docker VM & AI agent workspaces
        let asidePath = homePath + "/.aside"
        if FileManager.default.fileExists(atPath: asidePath) {
            jobs.append(BulkSizeJob(
                id: "dot_aside",
                label: "Aside AI Sessions & DB (~/.aside)",
                displayPath: asidePath,
                scanTargetFolderPath: nil,
                seeds: [asidePath],
                initialBytes: 0,
                deduplicateHardLinks: false,
                bucket: .appDatabasesAndAgents,
                note: "Active SQLite state.db + archived AI session logs",
                minReportBytes: 250_000_000,
                aggregateUnderAppSupportOther: false
            ))
        }
        let geminiPath = homePath + "/.gemini"
        if FileManager.default.fileExists(atPath: geminiPath) {
            jobs.append(BulkSizeJob(
                id: "dot_gemini",
                label: "Gemini / Antigravity Brains (~/.gemini)",
                displayPath: geminiPath,
                scanTargetFolderPath: nil,
                seeds: [geminiPath],
                initialBytes: 0,
                deduplicateHardLinks: false,
                bucket: .appDatabasesAndAgents,
                note: "Agent conversation transcripts, recordings & plugins",
                minReportBytes: 250_000_000,
                aggregateUnderAppSupportOther: false
            ))
        }
        let runitPath = homePath + "/.runitback"
        if FileManager.default.fileExists(atPath: runitPath) {
            let videoDir = runitPath + "/video"
            let hasVideoDir = FileManager.default.fileExists(atPath: videoDir)
            jobs.append(BulkSizeJob(
                id: "dot_runitback",
                label: "RunItBack Screen Recorder (~/.runitback)",
                displayPath: runitPath,
                scanTargetFolderPath: hasVideoDir ? videoDir : nil,
                seeds: [runitPath],
                initialBytes: 0,
                deduplicateHardLinks: false,
                bucket: .appDatabasesAndAgents,
                note: "Continuous screen recorder (~6 GB/day) + ML models — pause app before moving video",
                minReportBytes: 250_000_000,
                aggregateUnderAppSupportOther: false
            ))
        }
        let dockerPath = homePath + "/Library/Containers/com.docker.docker"
        if FileManager.default.fileExists(atPath: dockerPath) {
            jobs.append(BulkSizeJob(
                id: "docker_vm",
                label: "Docker Desktop Linux VM",
                displayPath: dockerPath,
                scanTargetFolderPath: nil,
                seeds: [dockerPath],
                initialBytes: 0,
                deduplicateHardLinks: false,
                bucket: .appDatabasesAndAgents,
                note: "Virtual disk image (Docker.raw) — prune via docker system prune",
                minReportBytes: 250_000_000,
                aggregateUnderAppSupportOther: false
            ))
        }

        let agentDotTargets: [(id: String, label: String, relPath: String, note: String)] = [
            ("dot_codex", "Codex CLI Data (~/.codex)", ".codex", "Codex sessions, caches & local state"),
            ("dot_bb", "BB Workspace (~/.bb)", ".bb", "Local tool state & cached runs"),
            ("dot_claude", "Claude Code Data (~/.claude)", ".claude", "Claude Code session transcripts & plugins"),
            ("dot_gsd", "GSD Agent Data (~/.gsd)", ".gsd", "Workspace logs & agent artifacts"),
            ("dot_grok", "Grok CLI Data (~/.grok)", ".grok", "Local CLI config & session state"),
            ("dot_antigravity", "Antigravity Data (~/.antigravity)", ".antigravity", "Local editor runtime & extensions"),
            ("dot_antigravity_ide", "Antigravity IDE (~/.antigravity-ide)", ".antigravity-ide", "IDE state & extension host cache")
        ]
        for a in agentDotTargets {
            let p = homePath + "/" + a.relPath
            if FileManager.default.fileExists(atPath: p) {
                jobs.append(BulkSizeJob(
                    id: a.id,
                    label: a.label,
                    displayPath: p,
                    scanTargetFolderPath: nil,
                    seeds: [p],
                    initialBytes: 0,
                    deduplicateHardLinks: false,
                    bucket: .appDatabasesAndAgents,
                    note: a.note,
                    minReportBytes: 250_000_000,
                    aggregateUnderAppSupportOther: false
                ))
            }
        }

        // 7. Non-Apple ~/Library/Application Support
        let appSupportPath = homePath + "/Library/Application Support"
        if let dir = opendir(appSupportPath) {
            while let entry = readdir(dir) {
                if Int32(entry.pointee.d_type) == DT_LNK { continue }
                let name = direntName(entry)
                if name == "." || name == ".." || name.hasPrefix(".") { continue }
                if appleAppSupportSkip.contains(name) || name.hasPrefix("com.apple.") { continue }
                let full = appSupportPath + "/" + name
                var st = stat()
                if Darwin.lstat(full, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
                    jobs.append(BulkSizeJob(
                        id: "appsupport_\(name)",
                        label: "\(name) (~/Library/Application Support)",
                        displayPath: full,
                        scanTargetFolderPath: nil,
                        seeds: [full],
                        initialBytes: 0,
                        deduplicateHardLinks: false,
                        bucket: .appDatabasesAndAgents,
                        note: "App database, Electron state & local indexes",
                        minReportBytes: 1_000_000_000,
                        aggregateUnderAppSupportOther: true
                    ))
                }
            }
            closedir(dir)
        }

        // 8. Non-Apple ~/Library/Containers & ~/Library/Group Containers
        let containersPath = homePath + "/Library/Containers"
        let nonAppleContainers = collectFilteredChildren(parentPath: containersPath) { name in
            name.contains(".") && !name.lowercased().contains("apple") && name != "com.docker.docker"
        }
        if !nonAppleContainers.dirs.isEmpty {
            jobs.append(BulkSizeJob(
                id: "third_party_containers",
                label: "Sandboxed App Containers (~/Library/Containers)",
                displayPath: containersPath,
                scanTargetFolderPath: nil,
                seeds: nonAppleContainers.dirs,
                initialBytes: 0,
                deduplicateHardLinks: false,
                bucket: .appDatabasesAndAgents,
                note: "Sandboxed third-party app data (Paste, Notability, Spark, etc.)",
                minReportBytes: 250_000_000,
                aggregateUnderAppSupportOther: false
            ))
        }

        let groupContainersPath = homePath + "/Library/Group Containers"
        let nonAppleGroupContainers = collectFilteredChildren(parentPath: groupContainersPath) { name in
            name.contains(".") && !name.lowercased().contains("apple")
        }
        if !nonAppleGroupContainers.dirs.isEmpty {
            jobs.append(BulkSizeJob(
                id: "third_party_group_containers",
                label: "Shared App Group Containers (~/Library/Group Containers)",
                displayPath: groupContainersPath,
                scanTargetFolderPath: nil,
                seeds: nonAppleGroupContainers.dirs,
                initialBytes: 0,
                deduplicateHardLinks: false,
                bucket: .appDatabasesAndAgents,
                note: "Shared app group databases & caches (Office, WhatsApp, Warp, etc.)",
                minReportBytes: 250_000_000,
                aggregateUnderAppSupportOther: false
            ))
        }

        // 9. Physical FileProvider offline cache backing store (avoid crawling live ~/Library/CloudStorage mounts which stall fileproviderd RPCs)
        let fpBackingPath = homePath + "/Library/Application Support/FileProvider"
        if FileManager.default.fileExists(atPath: fpBackingPath) {
            jobs.append(BulkSizeJob(
                id: "fileprovider_local_cache",
                label: "FileProvider Offline Cloud Cache",
                displayPath: fpBackingPath,
                scanTargetFolderPath: nil,
                seeds: [fpBackingPath],
                initialBytes: 0,
                deduplicateHardLinks: false,
                bucket: .appDatabasesAndAgents,
                note: "Locally materialized FileProvider blocks for ZeroDrive, Google Drive, OneDrive & Fabric",
                minReportBytes: 250_000_000,
                aggregateUnderAppSupportOther: false
            ))
        }

        // 10. /Applications, /opt, /Library
        jobs.append(BulkSizeJob(
            id: "sys_applications",
            label: "Installed Applications (/Applications)",
            displayPath: "/Applications",
            scanTargetFolderPath: nil,
            seeds: ["/Applications"],
            initialBytes: 0,
            deduplicateHardLinks: false,
            bucket: .lockedSystemAndApps,
            note: "Installed .app bundles on Mac",
            minReportBytes: 1,
            aggregateUnderAppSupportOther: false
        ))
        if FileManager.default.fileExists(atPath: "/opt") {
            jobs.append(BulkSizeJob(
                id: "sys_opt",
                label: "Homebrew & CLI Toolchains (/opt)",
                displayPath: "/opt",
                scanTargetFolderPath: nil,
                seeds: ["/opt"],
                initialBytes: 0,
                deduplicateHardLinks: true,
                bucket: .lockedSystemAndApps,
                note: "Homebrew formulae, casks & system CLI packages",
                minReportBytes: 1,
                aggregateUnderAppSupportOther: false
            ))
        }
        let sysLibRoot = collectFilteredChildren(parentPath: "/Library") { name in
            name != "Application Support" && !name.hasPrefix(".")
        }
        let sysLibAppSupport = collectFilteredChildren(parentPath: "/Library/Application Support") { name in
            name != "com.apple.TCC" && !name.hasPrefix(".")
        }
        jobs.append(BulkSizeJob(
            id: "sys_library",
            label: "System Library & Frameworks (/Library)",
            displayPath: "/Library",
            scanTargetFolderPath: nil,
            seeds: sysLibRoot.dirs + sysLibAppSupport.dirs,
            initialBytes: sysLibRoot.topLevelFileBytes + sysLibAppSupport.topLevelFileBytes,
            deduplicateHardLinks: false,
            bucket: .lockedSystemAndApps,
            note: "Shared system frameworks, audio plugins & Application Support",
            minReportBytes: 1,
            aggregateUnderAppSupportOther: false
        ))

        let measuredTotals = bulkSizeJobs(jobs)
        apfsGroup.wait()

        var devEntries: [MeasuredStorageEntry] = []
        var appEntries: [MeasuredStorageEntry] = []
        var lockedEntries: [MeasuredStorageEntry] = []
        var appSupportOtherBytes: Int64 = 0

        if apfsBox.res.osAndSystemBytes > 0 {
            lockedEntries.append(MeasuredStorageEntry(
                id: "apfs_system_os",
                label: "macOS Sealed OS, Preboot & Recovery",
                path: "",
                allocatedBytes: apfsBox.res.osAndSystemBytes,
                bucket: .lockedSystemAndApps,
                note: "Cryptographically signed macOS APFS system volumes"
            ))
        }
        if apfsBox.res.vmSwapBytes > 0 {
            lockedEntries.append(MeasuredStorageEntry(
                id: "apfs_vm_swap",
                label: "macOS VM Swap & Sleep Image",
                path: "",
                allocatedBytes: apfsBox.res.vmSwapBytes,
                bucket: .lockedSystemAndApps,
                note: "Active virtual memory & hibernation volumes"
            ))
        }

        if phase1Breakdown.smallWorkspaceFilesBytes >= 250_000_000 {
            appEntries.append(MeasuredStorageEntry(
                id: "small_workspace_files",
                label: "Source Code & Small Workspace Files (< 5 MB)",
                path: homePath,
                allocatedBytes: phase1Breakdown.smallWorkspaceFilesBytes,
                bucket: .appDatabasesAndAgents,
                note: "Code, configs & small assets under 5 MB across your user folders"
            ))
        }

        for (idx, job) in jobs.enumerated() {
            let bytes = measuredTotals[idx]
            if job.aggregateUnderAppSupportOther && bytes < job.minReportBytes {
                appSupportOtherBytes += bytes
                continue
            }
            guard bytes >= job.minReportBytes else { continue }
            let entry = MeasuredStorageEntry(
                id: job.id,
                label: job.label,
                path: job.displayPath,
                scanTargetFolderPath: job.scanTargetFolderPath,
                allocatedBytes: bytes,
                bucket: job.bucket,
                note: job.note
            )
            switch job.bucket {
            case .movableUserFiles: break
            case .devCachesAndTemp: devEntries.append(entry)
            case .appDatabasesAndAgents: appEntries.append(entry)
            case .lockedSystemAndApps: lockedEntries.append(entry)
            }
        }

        if appSupportOtherBytes >= 250_000_000 {
            appEntries.append(MeasuredStorageEntry(
                id: "appsupport_other",
                label: "Other App Support Databases (< 1 GB each)",
                path: appSupportPath,
                allocatedBytes: appSupportOtherBytes,
                bucket: .appDatabasesAndAgents,
                note: "Combined Application Support data across smaller apps"
            ))
        }

        let totalDev = devEntries.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        let totalApp = appEntries.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        let totalMeasuredLocked = lockedEntries.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        let remainderLocked = max(0, vol.usedBytes - phase1Breakdown.movableBytes - totalDev - totalApp - totalMeasuredLocked)

        if remainderLocked > 0 {
            lockedEntries.append(MeasuredStorageEntry(
                id: "macos_private_tcc",
                label: "macOS Spotlight, System Data & Apple Containers",
                path: "",
                allocatedBytes: remainderLocked,
                bucket: .lockedSystemAndApps,
                note: "SIP & TCC protected (Messages, Mail, Photos, Spotlight Metadata, /private/var/db, Trash) — manage in macOS Storage Settings"
            ))
        }

        let totalLocked = totalMeasuredLocked + remainderLocked
        let allEntries = (devEntries + appEntries + lockedEntries)
            .sorted { $0.allocatedBytes > $1.allocatedBytes }

        return MacDiskBreakdown(
            volumeTotalBytes: vol.totalBytes,
            availableImportantBytes: vol.availableImportantBytes,
            availableRawBytes: vol.availableRawBytes,
            purgeableBytes: vol.purgeableBytes,
            usedBytes: vol.usedBytes,
            movableBytes: phase1Breakdown.movableBytes,
            zeroDriveCacheBytes: phase1Breakdown.zeroDriveCacheBytes,
            nonMovableProtectedBytes: totalLocked,
            skippedUserBundlesBytes: phase1Breakdown.skippedUserBundlesBytes,
            skippedUserBundlesCount: phase1Breakdown.skippedUserBundlesCount,
            cloudGhostLogicalBytes: phase1Breakdown.cloudGhostLogicalBytes,
            cloudGhostCount: phase1Breakdown.cloudGhostCount,
            devCachesAndTempBytes: totalDev,
            appDatabasesAndAgentsBytes: totalApp,
            lockedSystemAndAppsBytes: totalLocked,
            smallWorkspaceFilesBytes: phase1Breakdown.smallWorkspaceFilesBytes,
            isDeepAuditComplete: true,
            bucketEntries: allEntries
        )
    }

    public nonisolated static func runHeadlessAuditAndExit() -> Never {
        let fmt: (Int64) -> String = { bytes in
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let t0 = Date()
        let p1 = performLocalMacScan(home: home, customRoot: nil)
        let p1Elapsed = Date().timeIntervalSince(t0)
        print(String(format: "[audit] Phase 1 finished in %.2fs (%d movable files, %@)", p1Elapsed, p1.items.count, fmt(p1.breakdown.movableBytes)))
        fflush(stdout)

        let t1 = Date()
        let bd = performDeepSystemBreakdown(
            home: home,
            phase1Breakdown: p1.breakdown,
            devSkippedArtifactDirs: p1.devSkippedArtifactDirs,
            labSkippedArtifactDirs: p1.labSkippedArtifactDirs,
            otherSkippedArtifactDirs: p1.otherSkippedArtifactDirs
        )
        let p2Elapsed = Date().timeIntervalSince(t1)
        saveCachedDiskMap(bd)

        print("=== ZERODRIVE STORAGE ADVISOR HEADLESS AUDIT ===")
        print(String(format: "Phase 1 (Movable Scan): %.2fs | Phase 2 (Deep System Audit): %.2fs | Total: %.2fs", p1Elapsed, p2Elapsed, p1Elapsed + p2Elapsed))
        print("SSD Total: \(fmt(bd.volumeTotalBytes)) | Used: \(fmt(bd.usedBytes)) | Available: \(fmt(bd.availableImportantBytes)) (Raw: \(fmt(bd.availableRawBytes)) + Purgeable: \(fmt(bd.purgeableBytes)))")
        print("Cloud Ghosts Excluded: \(fmt(bd.cloudGhostLogicalBytes)) across \(bd.cloudGhostCount) 0-byte stubs")
        print("")
        print("1) MOVABLE TO ZERODRIVE: \(fmt(bd.movableBytes)) (\(p1.items.count) files across \(p1.folderSummaries.count) folders)")
        for f in p1.folderSummaries {
            print("   - \(f.folderName): \(fmt(f.allocatedBytes)) (\(f.fileCount) files)")
        }
        print("")
        print("2) DEV CACHES & TEMP: \(fmt(bd.devCachesAndTempBytes))")
        for e in bd.bucketEntries.filter({ $0.bucket == .devCachesAndTemp }).prefix(12) {
            print("   - \(e.label): \(e.formattedSize)")
        }
        print("")
        print("3) APP DATABASES & RECORDERS: \(fmt(bd.appDatabasesAndAgentsBytes))")
        for e in bd.bucketEntries.filter({ $0.bucket == .appDatabasesAndAgents }).prefix(16) {
            print("   - \(e.label): \(e.formattedSize)")
        }
        print("")
        print("4) LOCKED MACOS & APPS: \(fmt(bd.lockedSystemAndAppsBytes))")
        for e in bd.bucketEntries.filter({ $0.bucket == .lockedSystemAndApps }) {
            print("   - \(e.label): \(e.formattedSize)")
        }
        let sumBuckets = bd.movableBytes + bd.devCachesAndTempBytes + bd.appDatabasesAndAgentsBytes + bd.lockedSystemAndAppsBytes
        print("")
        print("Bucket Reconciliation: Sum=\(fmt(sumBuckets)) vs Used=\(fmt(bd.usedBytes)) (Delta=\(sumBuckets - bd.usedBytes) B)")
        Darwin.exit(0)
    }

    private nonisolated static func computeFolderSummaries(from items: [StorageAdvisorItem]) -> [FolderReclaimSummary] {
        var map: [String: (path: String, count: Int, bytes: Int64)] = [:]

        for item in items {
            let key = item.sourceFolder
            let cur = map[key] ?? (item.sourceFolderPath, 0, 0)
            map[key] = (cur.path, cur.count + 1, cur.bytes + item.allocatedBytes)
        }

        return map.map { key, val in
            FolderReclaimSummary(
                id: key,
                folderName: key,
                folderPath: val.path,
                fileCount: val.count,
                allocatedBytes: val.bytes
            )
        }.sorted { $0.allocatedBytes > $1.allocatedBytes }
    }

    // MARK: - Nonisolated Cloud Discovery (Zero-Hydration Metadata Scan)

    private nonisolated static func performCloudScan(
        home: URL,
        rcloneURL: URL?,
        connectedOAuth: Set<ExternalCloudProvider>,
        configPath: String
    ) -> CloudScanOutput {
        var items: [CloudAdvisorItem] = []
        var providerCounts: [String: (label: String, icon: String, connected: Bool, count: Int, bytes: Int64)] = [:]
        let excludedPaths = Set(UserDefaults.standard.stringArray(forKey: ManageOnboardingSetup.excludedCloudsDefaultsKey) ?? [])

        func recordProvider(id: String, label: String, icon: String, connected: Bool, bytes: Int64, addCount: Int) {
            let cur = providerCounts[id] ?? (label, icon, connected, 0, 0)
            providerCounts[id] = (label, icon, connected || cur.connected, cur.count + addCount, cur.bytes + bytes)
        }

        // 1. iCloud Drive (Desktop, Documents, Mobile Documents) — strictly lstat, NEVER hydrate
        let icloudDocsPath = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").path
        let icloudRoots = [
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        ]
        var icloudFoundAny = false
        if !excludedPaths.contains(icloudDocsPath) {
            for root in icloudRoots {
                var st = stat()
                if Darwin.lstat(root.path, &st) == 0 {
                    icloudFoundAny = true
                    let scanned = scanDatalessCloudFolder(
                        rootPath: root.path,
                        displayPrefix: root.lastPathComponent == "com~apple~CloudDocs" ? "iCloud Drive" : "~/\(root.lastPathComponent)",
                        providerID: "icloud",
                        providerLabel: "iCloud Drive",
                        maxFiles: 80_000,
                        deadline: Date().addingTimeInterval(2.5)
                    )
                    for item in scanned {
                        items.append(item)
                        recordProvider(id: "icloud", label: "iCloud Drive", icon: "icloud.fill", connected: true, bytes: item.logicalBytes, addCount: 1)
                    }
                }
            }
        }
        if icloudFoundAny && providerCounts["icloud"] == nil {
            recordProvider(id: "icloud", label: "iCloud Drive", icon: "icloud.fill", connected: true, bytes: 0, addCount: 0)
        }

        // 2. ~/Library/CloudStorage/* providers (Google Drive, OneDrive, FabricDrive, Dropbox)
        let cloudStorageDir = home.appendingPathComponent("Library/CloudStorage")
        if let dir = opendir(cloudStorageDir.path) {
            defer { closedir(dir) }
            while let entry = readdir(dir) {
                let name = direntName(entry)
                if name.hasPrefix(".") || name.hasPrefix("ZeroDrive") { continue }
                if isArchivedTimestampCloudName(name) { continue }
                let fullPath = cloudStorageDir.path + "/" + name
                if excludedPaths.contains(fullPath) { continue }
                var st = stat()
                guard Darwin.lstat(fullPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }

                let (pid, plabel, picon): (String, String, String) = {
                    let low = name.lowercased()
                    if low.hasPrefix("googledrive-") {
                        let acct = String(name.dropFirst("GoogleDrive-".count))
                        return ("gdrive_\(acct)", "Google Drive (\(acct))", "externaldrive.connected.to.line.below")
                    } else if low.hasPrefix("onedrive") {
                        return ("onedrive_local", "OneDrive", "cloud.fill")
                    } else if low.contains("fabric") {
                        return ("fabric", "Fabric Drive", "folder.fill.badge.gearshape")
                    } else if low.hasPrefix("dropbox") {
                        return ("dropbox_local", "Dropbox", "shippingbox.fill")
                    }
                    return ("cloud_\(name)", name, "cloud.fill")
                }()

                let scanned = scanDatalessCloudFolder(
                    rootPath: fullPath,
                    displayPrefix: name,
                    providerID: pid,
                    providerLabel: plabel,
                    maxFiles: 35_000,
                    includeAllocatedFilesToo: pid == "fabric",
                    deadline: Date().addingTimeInterval(2.5)
                )
                recordProvider(id: pid, label: plabel, icon: picon, connected: true, bytes: 0, addCount: 0)
                for item in scanned {
                    items.append(item)
                    recordProvider(id: pid, label: plabel, icon: picon, connected: true, bytes: item.logicalBytes, addCount: 1)
                }
            }
        }

        // 3. Connected rclone OAuth external clouds (Google Drive, Dropbox, OneDrive)
        if let rcloneURL = rcloneURL {
            for extProvider in connectedOAuth {
                let pid = "oauth_\(extProvider.rawValue)"
                recordProvider(id: pid, label: "\(extProvider.displayName) (Direct Cloud)", icon: extProvider.systemIcon, connected: true, bytes: 0, addCount: 0)
                let remoteItems = fetchRcloneRemoteTopFiles(
                    rcloneURL: rcloneURL,
                    configPath: configPath,
                    remoteSection: extProvider.sectionName,
                    providerID: pid,
                    providerLabel: "\(extProvider.displayName) (Direct Cloud)"
                )
                for item in remoteItems {
                    items.append(item)
                    recordProvider(id: pid, label: item.providerLabel, icon: extProvider.systemIcon, connected: true, bytes: item.logicalBytes, addCount: 1)
                }
            }
        }

        // 4. Mark exact-size sibling duplicates (>= 10 MB in same parent directory)
        let markedItems = markSiblingDuplicates(items)
            .sorted { $0.logicalBytes > $1.logicalBytes }

        let summaries = providerCounts.map { key, val in
            CloudProviderSummary(
                id: key,
                label: val.label,
                icon: val.icon,
                isConnected: val.connected,
                itemCount: val.count,
                totalLogicalBytes: val.bytes
            )
        }.sorted { $0.totalLogicalBytes > $1.totalLogicalBytes }

        return CloudScanOutput(items: markedItems, providers: summaries)
    }

    private nonisolated static func isArchivedTimestampCloudName(_ name: String) -> Bool {
        guard name.hasSuffix(")"), let openIdx = name.lastIndex(of: "("), openIdx > name.startIndex else {
            return false
        }
        let prefix = name[..<openIdx]
        guard prefix.hasSuffix(" ") else { return false }
        let inner = name[name.index(after: openIdx)..<name.index(before: name.endIndex)]
        return inner.contains("-") && inner.contains(where: \.isNumber)
    }

    private nonisolated static func scanDatalessCloudFolder(
        rootPath: String,
        displayPrefix: String,
        providerID: String,
        providerLabel: String,
        maxFiles: Int,
        includeAllocatedFilesToo: Bool = false,
        deadline: Date = Date().addingTimeInterval(2.5)
    ) -> [CloudAdvisorItem] {
        var results: [CloudAdvisorItem] = []
        var stack: [String] = [rootPath]
        var visited = 0
        let minCloudBytes: Int64 = 5 * 1024 * 1024

        while let currentDir = stack.popLast() {
            if visited >= maxFiles || Date() >= deadline { break }
            guard let dir = opendir(currentDir) else {
                if errno == ETIMEDOUT { break }
                continue
            }
            defer { closedir(dir) }

            while let entry = readdir(dir) {
                if visited >= maxFiles || Date() >= deadline { break }
                let name = direntName(entry)
                if name == "." || name == ".." || name.hasPrefix(".") { continue }
                visited += 1

                let fullPath = currentDir + "/" + name
                var st = stat()
                guard Darwin.lstat(fullPath, &st) == 0 else { continue }
                let fType = st.st_mode & S_IFMT
                if fType == S_IFLNK { continue }

                if fType == S_IFDIR {
                    if excludedDirNames.contains(name) { continue }
                    let ext = (name as NSString).pathExtension.lowercased()
                    if excludedBundleExtensions.contains(ext) { continue }
                    stack.append(fullPath)
                    continue
                }

                guard fType == S_IFREG else { continue }
                let logical = Int64(st.st_size)
                guard logical >= minCloudBytes else { continue }

                let allocated = Int64(st.st_blocks) * 512
                let isDataless = (st.st_flags & sfDatalessFlag) != 0 || (allocated == 0 && logical > 0) || (allocated < logical / 2)
                if !isDataless && !includeAllocatedFilesToo {
                    continue
                }

                let rel: String = {
                    if fullPath.hasPrefix(rootPath + "/") {
                        return "\(displayPrefix)/\(fullPath.dropFirst(rootPath.count + 1))"
                    }
                    return "\(displayPrefix)/\(name)"
                }()

                let ext = (name as NSString).pathExtension.lowercased()
                let modDate = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))

                results.append(CloudAdvisorItem(
                    id: "\(providerID)::\(fullPath)",
                    name: name,
                    displayPath: rel,
                    providerID: providerID,
                    providerLabel: providerLabel,
                    localStubURL: URL(fileURLWithPath: fullPath),
                    rcloneRemoteSpec: nil,
                    logicalBytes: logical,
                    allocatedLocalBytes: allocated,
                    modifiedDate: modDate,
                    fileKind: classifyKind(ext: ext),
                    isPossibleDuplicate: false,
                    isSelected: false
                ))
            }
        }
        return results
    }

    private nonisolated static func fetchRcloneRemoteTopFiles(
        rcloneURL: URL,
        configPath: String,
        remoteSection: String,
        providerID: String,
        providerLabel: String
    ) -> [CloudAdvisorItem] {
        let proc = Process()
        proc.executableURL = rcloneURL
        proc.arguments = [
            "lsjson",
            "\(remoteSection):",
            "--files-only",
            "--max-depth", "2",
            "--config=\(configPath)",
            "--timeout=8s",
            "--contimeout=5s",
            "--retries=1"
        ]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()

        do {
            try proc.run()
            let deadline = Date().addingTimeInterval(10.0)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.08)
            }
            if proc.isRunning {
                proc.terminate()
                return []
            }
            guard proc.terminationStatus == 0 else { return [] }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return []
            }

            let iso = ISO8601DateFormatter()
            var items: [CloudAdvisorItem] = []
            for obj in arr {
                guard let path = obj["Path"] as? String,
                      let name = obj["Name"] as? String,
                      let size = (obj["Size"] as? NSNumber)?.int64Value,
                      size >= 5 * 1024 * 1024 else { continue }
                let modStr = obj["ModTime"] as? String ?? ""
                let modDate = iso.date(from: modStr) ?? Date()
                let ext = (name as NSString).pathExtension.lowercased()

                items.append(CloudAdvisorItem(
                    id: "\(providerID)::\(path)",
                    name: name,
                    displayPath: "\(remoteSection):/\(path)",
                    providerID: providerID,
                    providerLabel: providerLabel,
                    localStubURL: nil,
                    rcloneRemoteSpec: "\(remoteSection):\(path)",
                    logicalBytes: size,
                    allocatedLocalBytes: 0,
                    modifiedDate: modDate,
                    fileKind: classifyKind(ext: ext),
                    isPossibleDuplicate: false,
                    isSelected: false
                ))
            }
            return items
        } catch {
            return []
        }
    }

    private nonisolated static func markSiblingDuplicates(_ raw: [CloudAdvisorItem]) -> [CloudAdvisorItem] {
        struct GroupKey: Hashable {
            let parent: String
            let size: Int64
        }

        var groups: [GroupKey: [Int]] = [:]
        for (idx, item) in raw.enumerated() where item.logicalBytes >= 10 * 1024 * 1024 {
            let parent = (item.displayPath as NSString).deletingLastPathComponent
            let key = GroupKey(parent: parent, size: item.logicalBytes)
            groups[key, default: []].append(idx)
        }

        var items = raw
        var duplicateIndices: Set<Int> = []

        for (_, indices) in groups where indices.count > 1 {
            // Keep the cleanest-named copy (prefer descriptive name over raw timestamp like 2023-04-04_13-40-04.mp4)
            let sorted = indices.sorted { a, b in
                let aRaw = looksLikeTimestampFilename(items[a].name)
                let bRaw = looksLikeTimestampFilename(items[b].name)
                if aRaw != bRaw { return !aRaw }
                return items[a].name.count > items[b].name.count
            }
            for dupIdx in sorted.dropFirst() {
                duplicateIndices.insert(dupIdx)
            }
        }

        for idx in items.indices {
            let isDup = duplicateIndices.contains(idx)
            if isDup {
                let orig = items[idx]
                items[idx] = CloudAdvisorItem(
                    id: orig.id,
                    name: orig.name,
                    displayPath: orig.displayPath,
                    providerID: orig.providerID,
                    providerLabel: orig.providerLabel,
                    localStubURL: orig.localStubURL,
                    rcloneRemoteSpec: orig.rcloneRemoteSpec,
                    logicalBytes: orig.logicalBytes,
                    allocatedLocalBytes: orig.allocatedLocalBytes,
                    modifiedDate: orig.modifiedDate,
                    fileKind: orig.fileKind,
                    isPossibleDuplicate: true,
                    isSelected: false
                )
            }
        }
        return items
    }

    private nonisolated static func looksLikeTimestampFilename(_ name: String) -> Bool {
        let digits = name.prefix(10)
        return digits.filter(\.isNumber).count >= 8 && (name.contains("-") || name.contains("_"))
    }

    // MARK: - Remote Size Verification Helpers

    private nonisolated static func remoteFileSize(
        rcloneURL: URL,
        configPath: String,
        remotePath: String
    ) -> Int64? {
        let proc = Process()
        proc.executableURL = rcloneURL
        proc.arguments = [
            "lsjson",
            remotePath,
            "--files-only",
            "--config=\(configPath)",
            "--disable-http2",
            "--timeout=20s",
            "--retries=2"
        ]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()

        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let first = arr.first(where: { ($0["IsDir"] as? Bool) != true }),
               let sz = (first["Size"] as? NSNumber)?.int64Value {
                return sz
            }
            if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (dict["IsDir"] as? Bool) != true,
               let sz = (dict["Size"] as? NSNumber)?.int64Value {
                return sz
            }
            return nil
        } catch {
            return nil
        }
    }

    private nonisolated static func resolveCollisionRemotePath(
        rcloneURL: URL,
        configPath: String,
        proposedRemotePath: String,
        localLogicalSize: Int64
    ) -> String {
        guard let existingSize = remoteFileSize(rcloneURL: rcloneURL, configPath: configPath, remotePath: proposedRemotePath) else {
            return proposedRemotePath
        }
        if existingSize == localLogicalSize {
            return proposedRemotePath
        }
        let ns = proposedRemotePath as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        let suffix = String(UUID().uuidString.prefix(6))
        return ext.isEmpty ? "\(stem)_\(suffix)" : "\(stem)_\(suffix).\(ext)"
    }
}
