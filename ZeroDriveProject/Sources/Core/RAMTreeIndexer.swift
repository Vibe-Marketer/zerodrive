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

    /// Executes `POST /vfs/refresh` + `POST /operations/list` (`fastList: true`) for <1ms RAM search
    public func prewarmAll() async {
        isIndexing = true

        // 1. Trigger background vfs/refresh via RPC
        _ = await RcloneRCClient.shared.refreshVFSTree()

        // 2. Fetch full cloud tree via JSON-RPC `operations/list` with `fastList: true` (avoids slow POSIX NFS traversal)
        var nodes = await RcloneRCClient.shared.listCloudTree().filter { !$0.name.hasPrefix(".") }
        var seenPaths = Set(nodes.map { $0.relativePath })

        // 3. Merge any locally staged files in ~/ZeroDrive/Vault so newly dropped files appear immediately
        let mount = RcloneDaemonSupervisor.shared.mountPoint
        let vaultDir = mount.appendingPathComponent("Vault")
        if let vaultChildren = try? FileManager.default.contentsOfDirectory(
            at: vaultDir,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for fileURL in vaultChildren {
                let name = fileURL.lastPathComponent
                guard !name.hasPrefix(".") else { continue }
                let rel = "Vault/\(name)"
                if !seenPaths.contains(rel) {
                    let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    nodes.append(
                        CloudNode(
                            id: rel,
                            name: name,
                            relativePath: rel,
                            sizeBytes: Int64(size),
                            isFolder: isDir,
                            sourceCloud: "Vault"
                        )
                    )
                    seenPaths.insert(rel)
                }
            }
        }

        // 4. Ensure top-level folders (e.g. Vault) are present
        if nodes.isEmpty {
            if let children = try? FileManager.default.contentsOfDirectory(
                at: mount,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for fileURL in children {
                    let rel = fileURL.lastPathComponent
                    guard !rel.hasPrefix(".") else { continue }
                    let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    nodes.append(
                        CloudNode(
                            id: rel,
                            name: fileURL.lastPathComponent,
                            relativePath: rel,
                            sizeBytes: Int64(size),
                            isFolder: isDir,
                            sourceCloud: rel
                        )
                    )
                }
            }
        }

        self.indexedNodes = nodes
        self.isIndexing = false
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
