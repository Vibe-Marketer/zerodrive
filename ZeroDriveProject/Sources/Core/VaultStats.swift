import Foundation

/// Real numbers for the Overview page: total size and top-level folders of the user's ZeroDrive.
/// Dynamically updates as files land in ZeroDrive and reflects exact cloud vault state.
@MainActor
public final class VaultStats: ObservableObject {
    public static let shared = VaultStats()

    @Published public private(set) var totalBytes: Int64? = nil
    @Published public private(set) var folders: [String] = []
    @Published public private(set) var isLoading: Bool = false

    private struct Cache: Codable {
        var totalBytes: Int64
        var folders: [String]
        var updatedAt: Double?
    }

    private let cacheURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/rclone/zerodrive-stats.json")
    private var lastFullRefreshAt: Date? = nil
    private var activeSizeProcess: Process? = nil

    private init() {
        refreshFromCache()
    }

    public func refreshFromCache() {
        if let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            totalBytes = cache.totalBytes
            if !cache.folders.isEmpty {
                folders = cache.folders
            }
            if let ts = cache.updatedAt {
                lastFullRefreshAt = Date(timeIntervalSince1970: ts)
            }
        }
    }

    public func addFolderLocally(_ folderName: String) {
        let topName = folderName.split(separator: "/").first.map(String.init) ?? folderName
        guard !topName.isEmpty, !folders.contains(topName) else { return }
        folders = (folders + [topName]).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public var liveTotalBytes: Int64? {
        guard let base = totalBytes else { return nil }
        let moving = TurboMigrationManager.shared.telemetry.isRunning ? TurboMigrationManager.shared.telemetry.movedBytes : 0
        return base + moving
    }

    /// Fast (<300 ms) top-level folder refresh on launch; full bucket `rclone size` only runs when forced or uncached (>6h old).
    public func refresh(rclone: URL, forceFullSize: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
        let remote = "primary_vault:\(meta.bucketAndPrefix)"
        let config = MultiCloudCombineBuilder.shared.configPath.path

        if let dirsData = await Self.run(rclone, [
            "lsf", "--dirs-only", remote,
            "--config=\(config)",
            "--disable-http2",
            "--use-server-modtime"
        ]),
           let text = String(data: dirsData, encoding: .utf8) {
            folders = text.split(separator: "\n")
                .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "/ \r")) }
                .filter { !$0.isEmpty }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }

        let needsFullSize: Bool = {
            if forceFullSize { return true }
            guard totalBytes != nil else { return true }
            guard let last = lastFullRefreshAt else { return false }
            return Date().timeIntervalSince(last) > 6 * 3600
        }()

        if needsFullSize {
            if let sizeData = await runTrackedSize(rclone, [
                "size", "--fast-list", "--json", remote,
                "--config=\(config)",
                "--disable-http2",
                "--use-server-modtime",
                "--no-modtime",
                "--exclude=**/.DS_Store",
                "--exclude=**/._*"
            ]),
               let obj = try? JSONSerialization.jsonObject(with: sizeData) as? [String: Any],
               let bytes = (obj["bytes"] as? NSNumber)?.int64Value {
                totalBytes = bytes
                lastFullRefreshAt = Date()
            }
        }

        if let total = totalBytes,
           let data = try? JSONEncoder().encode(Cache(
               totalBytes: total,
               folders: folders,
               updatedAt: lastFullRefreshAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
           )) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    public func cancelActiveProcesses() {
        if let proc = activeSizeProcess, proc.isRunning {
            proc.terminate()
        }
        activeSizeProcess = nil
    }

    private func runTrackedSize(_ exe: URL, _ args: [String]) async -> Data? {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        self.activeSizeProcess = p
        defer { self.activeSizeProcess = nil }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try p.run()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    cont.resume(returning: p.terminationStatus == 0 ? data : nil)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    nonisolated private static func run(_ exe: URL, _ args: [String]) async -> Data? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = exe
                p.arguments = args
                let out = Pipe()
                p.standardOutput = out
                p.standardError = Pipe()
                do {
                    try p.run()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    cont.resume(returning: p.terminationStatus == 0 ? data : nil)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}
