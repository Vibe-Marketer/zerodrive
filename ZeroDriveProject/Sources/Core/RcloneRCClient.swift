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

    public func refreshVFSTree() async -> Bool {
        return await postRPC("vfs/refresh", ["recursive": "true", "_async": "true"]) != nil
    }

    public func setBandwidthCap(rate: String) async -> Bool {
        return await postRPC("core/bwlimit", ["rate": rate]) != nil
    }

    public func forgetFile(relativePath: String) async -> Bool {
        return await postRPC("vfs/forget", ["file": relativePath]) != nil
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
        guard let data = await postRPC("core/stats", [:], timeout: 1.5),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let speed = (json["speed"] as? Double) ?? 0.0
        let bytes = (json["bytes"] as? Int64) ?? Int64((json["bytes"] as? Int) ?? 0)
        let transferring = (json["transferring"] as? [[String: Any]])?.count ?? 0
        return RcloneCoreStatsDTO(
            speedBytesPerSec: speed,
            bytesTransferred: bytes,
            transferringCount: transferring
        )
    }

    public func fetchVFSStats() async -> RcloneVFSStatsDTO? {
        guard let data = await postRPC("vfs/stats", [:], timeout: 1.5),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let diskCache = json["diskCache"] as? [String: Any] else {
            return nil
        }
        let bytesUsed = (diskCache["bytesUsed"] as? Int64) ?? Int64((diskCache["bytesUsed"] as? Int) ?? 0)
        let inProgress = (diskCache["uploadsInProgress"] as? Int) ?? 0
        let queued = (diskCache["uploadsQueued"] as? Int) ?? 0
        return RcloneVFSStatsDTO(
            bytesUsed: bytesUsed,
            uploadsInProgress: inProgress,
            uploadsQueued: queued
        )
    }

    public func fetchVFSQueue() async -> [RcloneQueueItemDTO] {
        guard let data = await postRPC("vfs/queue", [:], timeout: 1.5),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let queue = json["queue"] as? [[String: Any]] else {
            return []
        }

        return queue.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let id = (item["id"] as? Int) ?? 0
            let size = (item["size"] as? Int64) ?? Int64((item["size"] as? Int) ?? 0)
            let expiry = (item["expiry"] as? Double) ?? 0.0
            let uploading = (item["uploading"] as? Bool) ?? false
            return RcloneQueueItemDTO(id: id, name: name, size: size, expiry: expiry, uploading: uploading)
        }
    }

    private func postRPC(_ endpoint: String, _ params: [String: Any], timeout: TimeInterval = 3.0) async -> Data? {
        guard let url = URL(string: endpoint, relativeTo: baseURL) else { return nil }
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
