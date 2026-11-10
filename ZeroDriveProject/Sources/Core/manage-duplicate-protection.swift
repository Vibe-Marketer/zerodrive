import Foundation
import CryptoKit

public struct DuplicateFileItem: Identifiable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let path: String
    public let sizeBytes: Int64
    public let modifiedDate: Date

    public init(url: URL, sizeBytes: Int64, modifiedDate: Date) {
        self.id = url.path
        self.url = url
        self.name = url.lastPathComponent
        self.path = url.path
        self.sizeBytes = sizeBytes
        self.modifiedDate = modifiedDate
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

public struct DuplicateGroup: Identifiable, Sendable {
    public let id: String
    public let fileHash: String
    public let fileSize: Int64
    public let fileName: String
    public let original: DuplicateFileItem
    public var duplicates: [DuplicateFileItem]

    public init(fileHash: String, fileSize: Int64, fileName: String, original: DuplicateFileItem, duplicates: [DuplicateFileItem]) {
        self.id = fileHash
        self.fileHash = fileHash
        self.fileSize = fileSize
        self.fileName = fileName
        self.original = original
        self.duplicates = duplicates
    }

    public var wastedBytes: Int64 {
        fileSize * Int64(duplicates.count)
    }

    public var formattedWastedBytes: String {
        ByteCountFormatter.string(fromByteCount: wastedBytes, countStyle: .file)
    }
}

@MainActor
public final class ManageDuplicateProtection: ObservableObject {
    public static let shared = ManageDuplicateProtection()

    @Published public private(set) var isScanning: Bool = false
    @Published public private(set) var isCleaning: Bool = false
    @Published public private(set) var scanProgress: Double = 0.0
    @Published public private(set) var statusMessage: String = "Duplicate Shield Active • 0 duplicates detected"
    @Published public private(set) var duplicateGroups: [DuplicateGroup] = []
    @Published public private(set) var totalWastedBytes: Int64 = 0
    @Published public private(set) var totalDuplicateFiles: Int = 0
    @Published public private(set) var totalFilesScanned: Int = 0
    @Published public private(set) var totalSpaceReclaimed: Int64 = 0
    @Published public private(set) var lastScanDate: Date? = nil
    @Published public var autoPreventDuplicatesOnTransfer: Bool = true

    // Cache of known hashes in Drive: [fileHash: path]
    private var knownCloudHashes: [String: String] = [:]

    private init() {
        loadPersistedStats()
    }

    private var statsFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/rclone/duplicate-protection-stats.json")
    }

    private func loadPersistedStats() {
        guard let data = try? Data(contentsOf: statsFileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        totalSpaceReclaimed = (dict["totalSpaceReclaimed"] as? NSNumber)?.int64Value ?? 0
        if let ts = dict["lastScanDate"] as? TimeInterval {
            lastScanDate = Date(timeIntervalSince1970: ts)
        }
    }

    private func savePersistedStats() {
        let dict: [String: Any] = [
            "totalSpaceReclaimed": totalSpaceReclaimed,
            "lastScanDate": lastScanDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? data.write(to: statsFileURL, options: .atomic)
        }
    }

    /// Checks if a file has an exact duplicate in ZeroDrive before moving or copying
    public func isDuplicateOfExistingFile(url: URL) -> (isDuplicate: Bool, matchingPath: String?) {
        guard autoPreventDuplicatesOnTransfer else { return (false, nil) }
        guard let hash = computeFileHash(url: url) else { return (false, nil) }
        if let existing = knownCloudHashes[hash] {
            return (true, existing)
        }
        return (false, nil)
    }

    /// Register a newly transferred file into the duplicate shield index
    public func registerTransferredFile(url: URL, cloudPath: String) {
        if let hash = computeFileHash(url: url) {
            knownCloudHashes[hash] = cloudPath
        }
    }

    /// Scans a directory (typically My Drive) for duplicate content
    public func startDuplicateScan(targetDirectory: URL? = nil) {
        guard !isScanning && !isCleaning else { return }
        isScanning = true
        scanProgress = 0.0
        statusMessage = "Scanning for files…"

        let scanURL: URL
        if let dir = targetDirectory {
            scanURL = dir
        } else {
            scanURL = RcloneDaemonSupervisor.shared.mountPoint.appendingPathComponent("My Drive")
        }

        Task.detached(priority: .userInitiated) {
            var scannedCount = 0
            var filesBySize: [Int64: [DuplicateFileItem]] = [:]

            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
            guard let enumerator = FileManager.default.enumerator(
                at: scanURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                await MainActor.run {
                    self.isScanning = false
                    self.statusMessage = "Scan completed • Target directory not accessible"
                }
                return
            }

            for case let fileURL as URL in enumerator {
                guard let res = try? fileURL.resourceValues(forKeys: Set(keys)),
                      res.isDirectory == false,
                      let size = res.fileSize,
                      size > 0 else {
                    continue
                }

                scannedCount += 1
                let mdate = res.contentModificationDate ?? Date()
                let item = DuplicateFileItem(url: fileURL, sizeBytes: Int64(size), modifiedDate: mdate)
                filesBySize[Int64(size), default: []].append(item)

                if scannedCount % 100 == 0 {
                    let currentCount = scannedCount
                    await MainActor.run {
                        self.totalFilesScanned = currentCount
                        self.statusMessage = "Indexed \(currentCount) files… analyzing potential duplicates"
                    }
                }
            }

            // Only examine groups where 2+ files share identical byte size
            let candidates = filesBySize.filter { $0.value.count > 1 }
            var groups: [DuplicateGroup] = []
            var wasted: Int64 = 0
            var duplicateCount = 0

            let totalCandidates = candidates.reduce(0) { $0 + $1.value.count }
            var candidateProcessed = 0

            for (_, items) in candidates {
                var hashBuckets: [String: [DuplicateFileItem]] = [:]
                for item in items {
                    candidateProcessed += 1
                    let progress = totalCandidates > 0 ? Double(candidateProcessed) / Double(totalCandidates) : 1.0

                    if let hash = Self.computeHashForFile(at: item.url) {
                        hashBuckets[hash, default: []].append(item)
                    }

                    if candidateProcessed % 20 == 0 {
                        await MainActor.run {
                            self.scanProgress = progress
                            self.statusMessage = "Inspecting cryptographic hashes (\(candidateProcessed)/\(totalCandidates))…"
                        }
                    }
                }

                for (hash, matchingItems) in hashBuckets where matchingItems.count > 1 {
                    // Sort so oldest file is considered the original
                    let sorted = matchingItems.sorted { $0.modifiedDate < $1.modifiedDate }
                    guard let original = sorted.first else { continue }
                    let duplicates = Array(sorted.dropFirst())

                    let group = DuplicateGroup(
                        fileHash: hash,
                        fileSize: original.sizeBytes,
                        fileName: original.name,
                        original: original,
                        duplicates: duplicates
                    )
                    groups.append(group)
                    wasted += group.wastedBytes
                    duplicateCount += duplicates.count
                }
            }

            await MainActor.run {
                self.duplicateGroups = groups
                self.totalDuplicateFiles = duplicateCount
                self.totalWastedBytes = wasted
                self.totalFilesScanned = scannedCount
                self.lastScanDate = Date()
                self.isScanning = false
                self.scanProgress = 1.0
                if duplicateCount == 0 {
                    self.statusMessage = "Shield Active • 0 duplicates found in \(scannedCount) files"
                } else {
                    let formattedWasted = ByteCountFormatter.string(fromByteCount: wasted, countStyle: .file)
                    self.statusMessage = "Found \(duplicateCount) duplicate files (\(formattedWasted) wasted)"
                }
                self.savePersistedStats()
            }
        }
    }

    /// Removes ALL detected duplicates at once, safely keeping the original file for each group
    public func removeAllDuplicates() {
        guard !duplicateGroups.isEmpty && !isCleaning else { return }
        isCleaning = true
        statusMessage = "Removing duplicates safely…"

        let groups = duplicateGroups

        Task.detached(priority: .userInitiated) {
            var reclaimed: Int64 = 0
            var deletedCount = 0

            for group in groups {
                for dup in group.duplicates {
                    do {
                        try FileManager.default.removeItem(at: dup.url)
                        reclaimed += dup.sizeBytes
                        deletedCount += 1
                    } catch {
                        // File might already be moved or locked
                    }
                }
            }

            await MainActor.run {
                self.totalSpaceReclaimed += reclaimed
                self.totalDuplicateFiles = 0
                self.totalWastedBytes = 0
                self.duplicateGroups = []
                self.isCleaning = false
                let formatted = ByteCountFormatter.string(fromByteCount: reclaimed, countStyle: .file)
                self.statusMessage = "Cleaned \(deletedCount) duplicates • Reclaimed \(formatted)"
                self.savePersistedStats()
            }
        }
    }

    /// Removes duplicates for a single group
    public func removeDuplicates(in group: DuplicateGroup) {
        guard let idx = duplicateGroups.firstIndex(where: { $0.id == group.id }) else { return }
        var reclaimed: Int64 = 0
        for dup in group.duplicates {
            try? FileManager.default.removeItem(at: dup.url)
            reclaimed += dup.sizeBytes
        }
        totalSpaceReclaimed += reclaimed
        totalWastedBytes -= group.wastedBytes
        totalDuplicateFiles -= group.duplicates.count
        duplicateGroups.remove(at: idx)
        savePersistedStats()
    }

    private func computeFileHash(url: URL) -> String? {
        Self.computeHashForFile(at: url)
    }

    nonisolated private static func computeHashForFile(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = Insecure.MD5()
        let bufferSize = 1024 * 1024 // 1 MB chunks
        while true {
            let data = handle.readData(ofLength: bufferSize)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}
