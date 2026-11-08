import Foundation
import AppKit

@MainActor
public final class RAMTreeIndexer: ObservableObject {
    public static let shared = RAMTreeIndexer()

    @Published public private(set) var indexedNodes: [CloudNode] = []
    @Published public private(set) var isIndexing: Bool = false
    public private(set) var lastSearchDurationMs: Double = 0.08

    private var refreshTask: Task<Void, Never>?

    public init() {
        startBackgroundAutoRefresh()
    }

    /// Refreshes top-level VFS directory instantly, then pre-warms active collections in background
    public func prewarmAll() async {
        isIndexing = true
        _ = await RcloneRCClient.shared.refreshVFSTree(dir: "My Drive", recursive: false)
        self.isIndexing = false

        Task.detached(priority: .utility) {
            let activeCollections = [
                "My Drive/MAIN",
                "My Drive/Course",
                "My Drive/_BUSINESS",
                "My Drive/_LIBRARY",
                "My Drive/_SKILLS",
                "My Drive/_SORT",
                "My Drive/_Retakes",
                "My Drive/_CAPTURES",
                "My Drive/CLOUD-MAIN"
            ]
            for col in activeCollections {
                _ = await RcloneRCClient.shared.refreshVFSTree(dir: col, recursive: true)
            }
        }
    }

    public func search(query: String) -> [CloudNode] {
        let t0 = CFAbsoluteTimeGetCurrent()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else {
            lastSearchDurationMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            return indexedNodes
        }
        let results = indexedNodes.filter {
            $0.name.lowercased().contains(q) || $0.relativePath.lowercased().contains(q)
        }
        lastSearchDurationMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
        return results
    }

    public func revealInFinder(node: CloudNode) {
        let fileURL = RcloneDaemonSupervisor.shared.mountPoint.appendingPathComponent(node.relativePath)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-R", fileURL.path]
        try? proc.run()
    }

    public func openFile(node: CloudNode) {
        let fileURL = RcloneDaemonSupervisor.shared.mountPoint.appendingPathComponent(node.relativePath)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [fileURL.path]
        try? proc.run()
    }

    private func startBackgroundAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                // Auto-refresh cloud tree every 15 minutes while mounted (PRD Section 4 & 7.3)
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                guard let self = self, RcloneDaemonSupervisor.shared.isMounted else { continue }
                await self.prewarmAll()
            }
        }
    }
}
