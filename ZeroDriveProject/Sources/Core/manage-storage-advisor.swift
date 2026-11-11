import Foundation
import AppKit

public enum StorageAdvisorCategory: String, CaseIterable, Identifiable, Sendable {
    case all = "All Recommendations"
    case cold = "Cold (>60 Days)"
    case heavy = "Heavy Hitters (>1 GB)"
    case installers = "Installers & Archives"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .all: return "sparkles"
        case .cold: return "snowflake"
        case .heavy: return "scalemass.fill"
        case .installers: return "archivebox.fill"
        }
    }
}

public struct StorageAdvisorItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let url: URL
    public let name: String
    public let path: String
    public let sizeBytes: Int64
    public let lastAccessedDate: Date
    public let modifiedDate: Date
    public let category: StorageAdvisorCategory
    public var isSelected: Bool

    public init(
        url: URL,
        sizeBytes: Int64,
        lastAccessedDate: Date,
        modifiedDate: Date,
        category: StorageAdvisorCategory,
        isSelected: Bool = true
    ) {
        self.id = url.path
        self.url = url
        self.name = url.lastPathComponent
        self.path = url.path
        self.sizeBytes = sizeBytes
        self.lastAccessedDate = lastAccessedDate
        self.modifiedDate = modifiedDate
        self.category = category
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
    }
}

@MainActor
public final class ManageStorageAdvisor: ObservableObject {
    public static let shared = ManageStorageAdvisor()

    @Published public private(set) var isScanning: Bool = false
    @Published public private(set) var isReclaiming: Bool = false
    @Published public private(set) var scanProgress: Double = 0.0
    @Published public private(set) var statusMessage: String = "Ready to scan Mac for reclaimable space"
    @Published public private(set) var items: [StorageAdvisorItem] = []
    @Published public private(set) var totalReclaimableBytes: Int64 = 0
    @Published public private(set) var totalSpaceReclaimedLifetime: Int64 = 0
    @Published public private(set) var lastScanDate: Date? = nil
    @Published public var selectedFilter: StorageAdvisorCategory = .all

    private var statsFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/rclone/storage-advisor-stats.json")
    }

    private init() {
        loadPersistedStats()
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

    public var filteredItems: [StorageAdvisorItem] {
        switch selectedFilter {
        case .all:
            return items
        case .cold:
            return items.filter { $0.category == .cold }
        case .heavy:
            return items.filter { $0.category == .heavy }
        case .installers:
            return items.filter { $0.category == .installers }
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
        if filterOnly && selectedFilter != .all {
            let targetCategory = selectedFilter
            for i in 0..<items.count {
                if items[i].category == targetCategory {
                    items[i].isSelected = true
                }
            }
        } else {
            for i in 0..<items.count {
                items[i].isSelected = true
            }
        }
    }

    public func deselectAll() {
        for i in 0..<items.count {
            items[i].isSelected = false
        }
    }

    /// Scans standard user directories for cold, large, or abandoned files
    public func startScan() {
        guard !isScanning && !isReclaiming else { return }

        isScanning = true
        scanProgress = 0.05
        statusMessage = "Discovering unorganized local files…"
        items = []

        let home = FileManager.default.homeDirectoryForCurrentUser
        let targetDirs = [
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Movies"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Documents")
        ].filter { FileManager.default.fileExists(atPath: $0.path) }

        Task.detached(priority: .userInitiated) {
            var foundItems: [StorageAdvisorItem] = []
            let now = Date()
            let sixtyDaysAgo = now.addingTimeInterval(-60 * 24 * 3600)
            let fourteenDaysAgo = now.addingTimeInterval(-14 * 24 * 3600)

            let installerExts: Set<String> = ["dmg", "pkg", "iso", "zip", "tar.gz", "tgz", "rar", "7z"]
            let totalDirs = Double(targetDirs.count)

            for (dirIndex, dir) in targetDirs.enumerated() {
                await MainActor.run {
                    self.statusMessage = "Scanning ~/\(dir.lastPathComponent)…"
                    self.scanProgress = 0.1 + (Double(dirIndex) / totalDirs) * 0.8
                }

                guard let enumerator = FileManager.default.enumerator(
                    at: dir,
                    includingPropertiesForKeys: [
                        .isRegularFileKey,
                        .fileSizeKey,
                        .contentAccessDateKey,
                        .contentModificationDateKey,
                        .isPackageKey
                    ],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }

                for case let fileURL as URL in enumerator {
                    guard let resourceValues = try? fileURL.resourceValues(forKeys: [
                        .isRegularFileKey,
                        .fileSizeKey,
                        .contentAccessDateKey,
                        .contentModificationDateKey,
                        .isPackageKey
                    ]) else { continue }

                    guard resourceValues.isRegularFile == true,
                          resourceValues.isPackage != true else { continue }

                    let size = Int64(resourceValues.fileSize ?? 0)
                    // Skip tiny files under 5 MB
                    guard size >= 5 * 1024 * 1024 else { continue }

                    let accessDate = resourceValues.contentAccessDate ?? resourceValues.contentModificationDate ?? Date.distantPast
                    let modDate = resourceValues.contentModificationDate ?? accessDate
                    let ext = fileURL.pathExtension.lowercased()

                    // Categorize:
                    var category: StorageAdvisorCategory? = nil

                    if installerExts.contains(ext) && (accessDate < fourteenDaysAgo || modDate < fourteenDaysAgo) {
                        category = .installers
                    } else if size >= 1024 * 1024 * 1024 { // > 1 GB
                        category = .heavy
                    } else if accessDate < sixtyDaysAgo && size >= 50 * 1024 * 1024 { // > 50 MB and cold
                        category = .cold
                    }

                    if let assignedCategory = category {
                        let item = StorageAdvisorItem(
                            url: fileURL,
                            sizeBytes: size,
                            lastAccessedDate: accessDate,
                            modifiedDate: modDate,
                            category: assignedCategory,
                            isSelected: true
                        )
                        foundItems.append(item)
                    }
                }
            }

            // Sort by size descending
            foundItems.sort { $0.sizeBytes > $1.sizeBytes }
            let totalBytes = foundItems.reduce(0) { $0 + $1.sizeBytes }

            await MainActor.run {
                self.items = foundItems
                self.totalReclaimableBytes = totalBytes
                self.lastScanDate = Date()
                self.savePersistedStats()
                self.isScanning = false
                self.scanProgress = 1.0
                self.statusMessage = "Found \(foundItems.count) items • \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)) reclaimable"
            }
        }
    }

    /// Reclaims selected files by moving them into ZeroDrive Cloud Vault and deleting local copies
    public func reclaimSelected(destinationSubfolder: String = "Cold Storage") async {
        let targets = items.filter { $0.isSelected }
        guard !targets.isEmpty else { return }

        isReclaiming = true
        statusMessage = "Preparing to offload \(targets.count) items to ZeroDrive…"

        let mountPoint = RcloneDaemonSupervisor.shared.mountPoint.appendingPathComponent("My Drive")
        let destinationDir = mountPoint.appendingPathComponent(destinationSubfolder)

        try? FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        var reclaimedBytesThisRun: Int64 = 0
        var successfullyMovedIds: Set<String> = []

        for (index, item) in targets.enumerated() {
            statusMessage = "[\(index + 1)/\(targets.count)] Offloading \(item.name)…"

            let destFile = destinationDir.appendingPathComponent(item.name)

            // Safe move / copy & verify
            do {
                // If destination already exists, resolve collision
                var targetURL = destFile
                if FileManager.default.fileExists(atPath: destFile.path) {
                    let base = destFile.deletingPathExtension().lastPathComponent
                    let ext = destFile.pathExtension
                    let uniqueName = "\(base)_\(UUID().uuidString.prefix(6))\(ext.isEmpty ? "" : ".\(ext)")"
                    targetURL = destinationDir.appendingPathComponent(uniqueName)
                }

                try FileManager.default.copyItem(at: item.url, to: targetURL)

                // Verify file size matches
                if let destValues = try? targetURL.resourceValues(forKeys: [.fileSizeKey]),
                   let destSize = destValues.fileSize,
                   Int64(destSize) == item.sizeBytes {
                    // Safe to remove local original file
                    try FileManager.default.removeItem(at: item.url)
                    reclaimedBytesThisRun += item.sizeBytes
                    successfullyMovedIds.insert(item.id)
                }
            } catch {
                NSLog("[StorageAdvisor] Failed to offload %@: %@", item.path, error.localizedDescription)
            }
        }

        // Update state
        totalSpaceReclaimedLifetime += reclaimedBytesThisRun
        items.removeAll { successfullyMovedIds.contains($0.id) }
        totalReclaimableBytes = items.reduce(0) { $0 + $1.sizeBytes }
        savePersistedStats()

        isReclaiming = false
        statusMessage = "Successfully reclaimed \(ByteCountFormatter.string(fromByteCount: reclaimedBytesThisRun, countStyle: .file)) of Mac SSD!"
    }
}
