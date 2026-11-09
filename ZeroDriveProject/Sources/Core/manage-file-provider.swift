import Foundation
import FileProvider

public actor ManageFileProvider {
    public static let shared = ManageFileProvider()

    private let appGroupIdentifier = "group.co.aisimple.zerodrive"
    private let domainIdentifier = NSFileProviderDomainIdentifier("ZeroDrive")

    private var pollerTask: Task<Void, Never>?
    private var lastPolledTimestamp: String?
    private var seenActivityIds: Set<String> = []
    private var isPolling = false

    public func syncCredentialsToAppGroup(
        endpoint: String = "https://api.zerodrive.dev",
        token: String = "zd_sec_b07b3671b1c45b32195f8353d4df8945ee31448699a361b32b6f8192a9b03633"
    ) {
        if let groupDefaults = UserDefaults(suiteName: appGroupIdentifier) {
            groupDefaults.set(endpoint, forKey: "api_endpoint")
            groupDefaults.set(token, forKey: "api_token")
            groupDefaults.synchronize()
        }
    }

    public func registerDomainIfNeeded() async {
        syncCredentialsToAppGroup()

        let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: "ZeroDrive")
        // Clean any stale or orphaned domain state first
        do {
            try await NSFileProviderManager.remove(domain)
            NSLog("[ZeroDrive] Purged stale domain state")
        } catch {}

        do {
            try await NSFileProviderManager.add(domain)
            NSLog("[ZeroDrive] FileProvider domain successfully registered: %@", domain.displayName)
            setupCloudStorageSymlink()
            startBackgroundPoller()
        } catch {
            NSLog("[ZeroDrive] FileProvider domain registration notice: %@", error.localizedDescription)
            setupCloudStorageSymlink()
            startBackgroundPoller()
        }
    }

    public func setupCloudStorageSymlink() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let cloudStoragePath = homeDir.appendingPathComponent("Library/CloudStorage/ZeroDrive").path
        let userSymlink = homeDir.appendingPathComponent("ZeroDrive").path

        if FileManager.default.fileExists(atPath: cloudStoragePath) {
            do {
                if FileManager.default.fileExists(atPath: userSymlink) {
                    let dest = try FileManager.default.destinationOfSymbolicLink(atPath: userSymlink)
                    if dest == cloudStoragePath { return }
                    try FileManager.default.removeItem(atPath: userSymlink)
                }
                try FileManager.default.createSymbolicLink(atPath: userSymlink, withDestinationPath: cloudStoragePath)
                NSLog("[ZeroDrive] Updated ~/ZeroDrive symlink -> %@", cloudStoragePath)
            } catch {
                NSLog("[ZeroDrive] Symlink update warning: %@", error.localizedDescription)
            }
        }
    }

    public func startBackgroundPoller(intervalSeconds: Double = 5.0) {
        guard !isPolling else { return }
        isPolling = true
        NSLog("[ZeroDrive] Starting FileProvider background activity poller (interval: %.1fs)", intervalSeconds)
        pollerTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self = self {
                    await self.pollRemoteActivity()
                }
                do {
                    try await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
                } catch {
                    break
                }
            }
        }
    }

    public func stopBackgroundPoller() {
        pollerTask?.cancel()
        pollerTask = nil
        isPolling = false
        NSLog("[ZeroDrive] Stopped FileProvider background activity poller")
    }

    public func pollRemoteActivity() async {
        var endpoint = "https://api.zerodrive.dev"
        var token = "zd_sec_b07b3671b1c45b32195f8353d4df8945ee31448699a361b32b6f8192a9b03633"
        if let groupDefaults = UserDefaults(suiteName: appGroupIdentifier) {
            if let ep = groupDefaults.string(forKey: "api_endpoint"), !ep.isEmpty {
                endpoint = ep
            }
            if let tok = groupDefaults.string(forKey: "api_token"), !tok.isEmpty {
                token = tok
            }
        }

        let cleanEndpoint = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(cleanEndpoint)/v1/activity?limit=50") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("ZeroDrive-FileProvider-Poller/3.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return
            }

            struct ActivityItem: Codable {
                let id: String
                let timestamp: String
                let action: String
                let path: String?
                let source: String?
                let destination: String?
            }

            struct ActivityLedger: Codable {
                let ok: Bool
                let count: Int?
                let activities: [ActivityItem]
            }

            let decoded = try JSONDecoder().decode(ActivityLedger.self, from: data)

            // On initial poll, initialize baseline without signaling stale history
            if lastPolledTimestamp == nil {
                if let latest = decoded.activities.first {
                    lastPolledTimestamp = latest.timestamp
                    seenActivityIds = Set(decoded.activities.map { $0.id })
                    NSLog("[ZeroDrive] Remote activity poller initialized at timestamp: %@", latest.timestamp)
                } else {
                    let iso = ISO8601DateFormatter()
                    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    lastPolledTimestamp = iso.string(from: Date())
                }
                return
            }

            let lastTs = lastPolledTimestamp ?? ""
            let newActivities = decoded.activities.filter { act in
                guard !seenActivityIds.contains(act.id) else { return false }
                if !lastTs.isEmpty {
                    return act.timestamp >= lastTs
                }
                return true
            }

            if newActivities.isEmpty {
                return
            }

            for act in newActivities {
                seenActivityIds.insert(act.id)
                if lastPolledTimestamp == nil || act.timestamp > lastPolledTimestamp! {
                    lastPolledTimestamp = act.timestamp
                }
            }

            if seenActivityIds.count > 1000 {
                seenActivityIds = Set(decoded.activities.map { $0.id })
            }

            let relevantActions: Set<String> = [
                "create_file", "write_file", "delete_file", "move_file", "edit_file", "copy_file"
            ]

            var containersToSignal: Set<NSFileProviderItemIdentifier> = []

            for act in newActivities {
                guard relevantActions.contains(act.action) else { continue }
                NSLog("[ZeroDrive] Remote delta activity detected: action=%@, path=%@", act.action, act.path ?? act.destination ?? act.source ?? "")

                if let p = act.path {
                    containersToSignal.insert(parentContainerIdentifier(for: p))
                }
                if let dst = act.destination {
                    containersToSignal.insert(parentContainerIdentifier(for: dst))
                }
                if let src = act.source {
                    containersToSignal.insert(parentContainerIdentifier(for: src))
                }
            }

            // Always signal root container to trigger parent directory refresh
            containersToSignal.insert(.rootContainer)

            let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: "ZeroDrive")
            guard let manager = NSFileProviderManager(for: domain) else {
                NSLog("[ZeroDrive] NSFileProviderManager unavailable for domain: %@", domainIdentifier.rawValue)
                return
            }

            for containerId in containersToSignal {
                do {
                    try await manager.signalEnumerator(for: containerId)
                    NSLog("[ZeroDrive] Remote delta signaled FileProvider for container: %@", containerId.rawValue)
                } catch {
                    NSLog("[ZeroDrive] signalEnumerator failed for %@: %@", containerId.rawValue, error.localizedDescription)
                }
            }

            do {
                try await manager.signalEnumerator(for: .workingSet)
                NSLog("[ZeroDrive] Remote delta signaled FileProvider for workingSet")
            } catch {
                NSLog("[ZeroDrive] signalEnumerator workingSet notice: %@", error.localizedDescription)
            }
        } catch {
            NSLog("[ZeroDrive] Poller fetch error: %@", error.localizedDescription)
        }
    }

    private func parentContainerIdentifier(for rawPath: String) -> NSFileProviderItemIdentifier {
        let clean = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let lastSlash = clean.lastIndex(of: "/") {
            let parentPath = String(clean[..<lastSlash])
            if !parentPath.isEmpty {
                return NSFileProviderItemIdentifier(parentPath)
            }
        }
        return .rootContainer
    }
}
