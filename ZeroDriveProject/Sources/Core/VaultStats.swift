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
    }

    private let cacheURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/rclone/zerodrive-stats.json")

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
        }
    }

    public var liveTotalBytes: Int64? {
        guard let base = totalBytes else { return nil }
        let moving = TurboMigrationManager.shared.telemetry.isRunning ? TurboMigrationManager.shared.telemetry.movedBytes : 0
        return base + moving
    }

    public func refresh(rclone: URL) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
        let remote = "primary_vault:\(meta.bucketAndPrefix)"
        let config = MultiCloudCombineBuilder.shared.configPath.path

        if let dirsData = await Self.run(rclone, ["lsf", "--dirs-only", remote, "--config=\(config)"]),
           let text = String(data: dirsData, encoding: .utf8) {
            folders = text.split(separator: "\n")
                .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "/ \r")) }
                .filter { !$0.isEmpty }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }

        if let sizeData = await Self.run(rclone, ["size", "--fast-list", "--json", remote, "--config=\(config)",
                                                  "--exclude=**/.DS_Store", "--exclude=**/._*"]),
           let obj = try? JSONSerialization.jsonObject(with: sizeData) as? [String: Any],
           let bytes = (obj["bytes"] as? NSNumber)?.int64Value {
            totalBytes = bytes
        }

        if let total = totalBytes,
           let data = try? JSONEncoder().encode(Cache(totalBytes: total, folders: folders)) {
            try? data.write(to: cacheURL, options: .atomic)
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
