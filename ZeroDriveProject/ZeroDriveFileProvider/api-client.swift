import Foundation
import FileProvider

public actor ZeroDriveAPIClient {
    public static let shared = ZeroDriveAPIClient()

    private let appGroupIdentifier = "group.co.aisimple.zerodrive"
    private let defaultBaseURL = URL(string: "https://api.zerodrive.dev")!
    private let fallbackToken = "zd_sec_b07b3671b1c45b32195f8353d4df8945ee31448699a361b32b6f8192a9b03633"

    private var baseURL: URL {
        if let groupDefaults = UserDefaults(suiteName: appGroupIdentifier),
           let customEndpoint = groupDefaults.string(forKey: "api_endpoint"),
           let url = URL(string: customEndpoint) {
            return url
        }
        return defaultBaseURL
    }

    private var authToken: String {
        if let groupDefaults = UserDefaults(suiteName: appGroupIdentifier),
           let token = groupDefaults.string(forKey: "api_token"),
           !token.isEmpty {
            return token
        }
        return fallbackToken
    }

    private func makeRequest(endpoint: String, method: String = "GET", queryParams: [String: String] = [:]) throws -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(endpoint), resolvingAgainstBaseURL: true)
        if !queryParams.isEmpty {
            components?.queryItems = queryParams.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else {
            throw NSError(domain: "ZeroDriveAPI", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid URL for endpoint \(endpoint)"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10.0
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("ZeroDrive-FileProvider/3.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    public func fetchItem(path: String) async throws -> RemoteItemRecord {
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let request = try makeRequest(endpoint: "v1/files/stat", queryParams: ["path": cleanPath])
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ZeroDriveAPI", code: 500, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response"])
        }

        if httpResponse.statusCode == 404 {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        }

        guard httpResponse.statusCode == 200 else {
            throw NSError(domain: "ZeroDriveAPI", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Stat failed: HTTP \(httpResponse.statusCode)"])
        }

        struct StatResponse: Codable {
            let ok: Bool
            let item: RemoteItemRecord
        }

        let decoded = try JSONDecoder().decode(StatResponse.self, from: data)
        return decoded.item
    }

    public func listFiles(
        path: String,
        cursor: String? = nil,
        limit: Int = 500
    ) async throws -> (items: [RemoteItemRecord], nextCursor: String?, hasMore: Bool) {
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var params: [String: String] = [
            "path": cleanPath,
            "limit": String(limit)
        ]
        if let cursor = cursor, !cursor.isEmpty {
            params["cursor"] = cursor
        }

        let request = try makeRequest(endpoint: "v1/files", queryParams: params)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "ZeroDriveAPI", code: 502, userInfo: [NSLocalizedDescriptionKey: "Failed to list files"])
        }

        struct RawDir: Codable {
            let name: String
            let path: String
        }

        struct RawFile: Codable {
            let name: String
            let path: String
            let size: Int64
            let modified: String?
            let mimeType: String?
            let etag: String?

            enum CodingKeys: String, CodingKey {
                case name
                case path
                case size
                case modified
                case mimeType = "mime_type"
                case etag
            }
        }

        struct ListResponse: Codable {
            let ok: Bool
            let directories: [RawDir]
            let files: [RawFile]
            let nextCursor: String?
            let hasMore: Bool?

            enum CodingKeys: String, CodingKey {
                case ok
                case directories
                case files
                case nextCursor = "next_cursor"
                case hasMore = "has_more"
            }
        }

        let decoded = try JSONDecoder().decode(ListResponse.self, from: data)
        var items: [RemoteItemRecord] = []

        for dir in decoded.directories {
            items.append(RemoteItemRecord(
                name: dir.name,
                path: dir.path,
                isDirectory: true,
                size: 0,
                modified: nil,
                mimeType: nil,
                etag: nil
            ))
        }

        for file in decoded.files {
            items.append(RemoteItemRecord(
                name: file.name,
                path: file.path,
                isDirectory: false,
                size: file.size,
                modified: file.modified,
                mimeType: file.mimeType,
                etag: file.etag
            ))
        }

        let nextCursor = decoded.nextCursor
        let hasMore = decoded.hasMore ?? (nextCursor != nil)

        return (items, nextCursor, hasMore)
    }

    public func downloadFile(path: String, to destinationURL: URL) async throws {
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let request = try makeRequest(endpoint: "vault/download", queryParams: ["path": cleanPath])

        let (tempDownloadedURL, response) = try await URLSession.shared.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "ZeroDriveAPI", code: 502, userInfo: [NSLocalizedDescriptionKey: "Download failed for \(cleanPath)"])
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: tempDownloadedURL, to: destinationURL)
    }

    public func uploadFile(path: String, from sourceURL: URL) async throws -> RemoteItemRecord {
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var request = try makeRequest(endpoint: "vault/upload", method: "POST", queryParams: ["path": cleanPath])
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: sourceURL)
        request.httpBody = fileData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "ZeroDriveAPI", code: 502, userInfo: [NSLocalizedDescriptionKey: "Upload failed for \(cleanPath)"])
        }

        struct UploadResponse: Codable {
            let ok: Bool
            let path: String
            let size: Int64
            let mimeType: String?
            let etag: String?

            enum CodingKeys: String, CodingKey {
                case ok
                case path
                case size
                case mimeType = "mime_type"
                case etag
            }
        }

        let decoded = try JSONDecoder().decode(UploadResponse.self, from: data)
        let fileName = (decoded.path as NSString).lastPathComponent
        return RemoteItemRecord(
            name: fileName,
            path: decoded.path,
            isDirectory: false,
            size: decoded.size,
            modified: ISO8601DateFormatter().string(from: Date()),
            mimeType: decoded.mimeType,
            etag: decoded.etag
        )
    }

    public func deleteItem(path: String) async throws {
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let request = try makeRequest(endpoint: "v1/files", method: "DELETE", queryParams: ["path": cleanPath])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "ZeroDriveAPI", code: 502, userInfo: [NSLocalizedDescriptionKey: "Delete failed for \(cleanPath)"])
        }
    }

    public func fetchActivities(limit: Int = 100) async throws -> [RemoteActivityRecord] {
        let request = try makeRequest(endpoint: "v1/activity", queryParams: ["limit": String(limit)])
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 502
            throw NSError(domain: "ZeroDriveAPI", code: code, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch activities (HTTP \(code))"])
        }

        struct ActivityResponse: Codable {
            let ok: Bool
            let count: Int?
            let activities: [RemoteActivityRecord]
        }

        let decoded = try JSONDecoder().decode(ActivityResponse.self, from: data)
        return decoded.activities
    }
}

public struct RemoteActivityRecord: Codable, Sendable {
    public let id: String
    public let timestamp: String
    public let action: String
    public let path: String?
    public let source: String?
    public let destination: String?
    public let size: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case action
        case path
        case source
        case destination
        case size
    }
}
