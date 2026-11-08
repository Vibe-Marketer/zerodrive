import Foundation

public struct RcloneQueueItemDTO: Sendable {
    public let id: Int
    public let name: String
    public let size: Int64
    public let expiry: Double
    public let uploading: Bool
}

public struct RcloneVFSStatsDTO: Sendable {
    public let bytesUsed: Int64
    public let uploadsInProgress: Int
    public let uploadsQueued: Int
}

public struct RcloneCoreStatsDTO: Sendable {
    public let speedBytesPerSec: Double
    public let bytesTransferred: Int64
    public let transferringCount: Int
}

public actor RcloneRCClient {
    public static let shared = RcloneRCClient()

    private let baseURL = URL(string: "http://127.0.0.1:55729")!
    private let transferBaseURL = URL(string: "http://127.0.0.1:55731")!

    public func ping() async -> Bool {
        guard let url = URL(string: "core/pid", relativeTo: baseURL) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 1.2

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    public func refreshVFSTree(dir: String = "My Drive", recursive: Bool = false) async -> Bool {
        var params: [String: Any] = [
            "_async": "true",
            "dir": dir
        ]
        if recursive {
            params["recursive"] = "true"
        }
        return await postRPC("vfs/refresh", params) != nil
    }

    public func setBandwidthCap(rate: String) async -> Bool {
        return await postRPC("core/bwlimit", ["rate": rate]) != nil
    }

    public func forgetFile(relativePath: String) async -> Bool {
        return await postRPC("vfs/forget", ["file": relativePath]) != nil
    }

    public func forgetAll() async -> Bool {
        return await postRPC("vfs/forget", [:]) != nil
    }

    public func setQueueExpiry(expiry: Int, itemId: Int? = nil) async -> Bool {
        var params: [String: Any] = ["expiry": expiry]
        if let id = itemId {
            params["id"] = id
        }
        return await postRPC("vfs/queue/set-expiry", params) != nil
    }

    /// Calls `POST /operations/list` with `fastList: true` for sub-second cloud tree indexing
    public func listCloudTree(fs: String = "ZeroDriveUnified:", remote: String = "") async -> [CloudNode] {
        let payload: [String: Any] = [
            "fs": fs,
            "remote": remote,
            "opt": [
                "recurse": true,
                "fastList": true
            ]
        ]
        guard let data = await postRPC("operations/list", payload, timeout: 15.0),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["list"] as? [[String: Any]] else {
            return []
        }

        var nodes: [CloudNode] = []
        nodes.reserveCapacity(list.count)

        for entry in list {
            let path = (entry["Path"] as? String) ?? ""
            let name = (entry["Name"] as? String) ?? (path as NSString).lastPathComponent
            guard !name.isEmpty, name != ".metadata_never_index", name != ".DS_Store" else { continue }
            let size = (entry["Size"] as? Int64) ?? Int64((entry["Size"] as? Int) ?? 0)
            let isDir = (entry["IsDir"] as? Bool) ?? false
            let source = path.components(separatedBy: "/").first ?? "Vault"

            nodes.append(
                CloudNode(
                    id: path,
                    name: name,
                    relativePath: path,
                    sizeBytes: max(0, size),
                    isFolder: isDir,
                    sourceCloud: source
                )
            )
        }
        return nodes
    }

    public func fetchCoreStats() async -> RcloneCoreStatsDTO? {
        var totalSpeed = 0.0
        var totalBytes: Int64 = 0
        var totalTransferring = 0

        if let data = await postRPC("core/stats", [:], timeout: 1.5),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            totalSpeed += (json["speed"] as? Double) ?? 0.0
            totalBytes += (json["bytes"] as? Int64) ?? Int64((json["bytes"] as? Int) ?? 0)
            totalTransferring += (json["transferring"] as? [[String: Any]])?.count ?? 0
        }

        if let txData = await postRPC("core/stats", [:], timeout: 1.0, base: transferBaseURL),
           let txJson = try? JSONSerialization.jsonObject(with: txData) as? [String: Any] {
            totalSpeed += (txJson["speed"] as? Double) ?? 0.0
            totalBytes += (txJson["bytes"] as? Int64) ?? Int64((txJson["bytes"] as? Int) ?? 0)
            totalTransferring += (txJson["transferring"] as? [[String: Any]])?.count ?? 0
        }

        return RcloneCoreStatsDTO(
            speedBytesPerSec: totalSpeed,
            bytesTransferred: totalBytes,
            transferringCount: totalTransferring
        )
    }

    public func fetchVFSStats() async -> RcloneVFSStatsDTO? {
        var bytesUsed: Int64 = 0
        var inProgress = 0
        var queued = 0

        if let data = await postRPC("vfs/stats", [:], timeout: 1.5),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let diskCache = json["diskCache"] as? [String: Any] {
            bytesUsed = (diskCache["bytesUsed"] as? Int64) ?? Int64((diskCache["bytesUsed"] as? Int) ?? 0)
            inProgress = (diskCache["uploadsInProgress"] as? Int) ?? 0
            queued = (diskCache["uploadsQueued"] as? Int) ?? 0
        }

        if let txData = await postRPC("core/stats", [:], timeout: 1.0, base: transferBaseURL),
           let txJson = try? JSONSerialization.jsonObject(with: txData) as? [String: Any] {
            let activeTx = (txJson["transferring"] as? [[String: Any]])?.count ?? 0
            let totalTx = (txJson["totalTransfers"] as? Int) ?? 0
            let doneTx = (txJson["transfers"] as? Int) ?? 0
            inProgress += activeTx
            queued += max(0, totalTx - doneTx - activeTx)
        }

        return RcloneVFSStatsDTO(
            bytesUsed: bytesUsed,
            uploadsInProgress: inProgress,
            uploadsQueued: queued
        )
    }

    public func fetchVFSQueue() async -> [RcloneQueueItemDTO] {
        var items: [RcloneQueueItemDTO] = []

        if let data = await postRPC("vfs/queue", [:], timeout: 1.5),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let queue = json["queue"] as? [[String: Any]] {
            items.append(contentsOf: queue.compactMap { item in
                guard let name = item["name"] as? String else { return nil }
                let id = (item["id"] as? Int) ?? 0
                let size = (item["size"] as? Int64) ?? Int64((item["size"] as? Int) ?? 0)
                let expiry = (item["expiry"] as? Double) ?? 0.0
                let uploading = (item["uploading"] as? Bool) ?? false
                return RcloneQueueItemDTO(id: id, name: name, size: size, expiry: expiry, uploading: uploading)
            })
        }

        if let txData = await postRPC("core/stats", [:], timeout: 1.0, base: transferBaseURL),
           let txJson = try? JSONSerialization.jsonObject(with: txData) as? [String: Any],
           let transferring = txJson["transferring"] as? [[String: Any]] {
            for (idx, tx) in transferring.enumerated() {
                guard let name = tx["name"] as? String else { continue }
                let size = (tx["size"] as? Int64) ?? Int64((tx["size"] as? Int) ?? 0)
                let eta = (tx["eta"] as? Double) ?? 0.0
                items.append(
                    RcloneQueueItemDTO(
                        id: 10000 + idx,
                        name: "_CONTENT/\(name)",
                        size: size,
                        expiry: eta,
                        uploading: true
                    )
                )
            }
        }

        return items
    }

    private func postRPC(_ endpoint: String, _ params: [String: Any], timeout: TimeInterval = 3.0, base: URL? = nil) async -> Data? {
        guard let url = URL(string: endpoint, relativeTo: base ?? baseURL) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try? JSONSerialization.data(withJSONObject: params)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        } catch {
            return nil
        }
    }
}
