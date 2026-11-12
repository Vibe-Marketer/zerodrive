import Foundation
import FileProvider

public actor ManageFileProvider {
    public static let shared = ManageFileProvider()

    private let appGroupIdentifier = "group.co.aisimple.zerodrive"
    private let domainIdentifier = NSFileProviderDomainIdentifier("ZeroDrive")

    private var pollerTask: Task<Void, Never>?
    private var sseTask: Task<Void, Never>?
    private var lastPolledTimestamp: String?
    private var seenActivityIds: Set<String> = []
    private var isPolling = false
    private var isSSEListening = false
    private var isSSEConnected = false

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
        let existingDomains = (try? await NSFileProviderManager.domains()) ?? []
        if existingDomains.contains(where: { $0.identifier == domainIdentifier }) {
            setupCloudStorageSymlink()
            startBackgroundPoller()
            startRealtimeEventListener()
            return
        }

        do {
            try await NSFileProviderManager.add(domain)
            NSLog("[ZeroDrive] FileProvider domain successfully registered: %@", domain.displayName)
            setupCloudStorageSymlink()
            startBackgroundPoller()
            startRealtimeEventListener()
        } catch {
            NSLog("[ZeroDrive] FileProvider domain registration notice: %@", error.localizedDescription)
            setupCloudStorageSymlink()
            startBackgroundPoller()
            startRealtimeEventListener()
        }
    }

    public func setupCloudStorageSymlink() {
        // Keep ~/ZeroDrive pointed at ~/.zerodrive/My Drive whenever the primary NFS vault is configured
        guard !MultiCloudCombineBuilder.shared.hasConfiguredPrimaryVault() else { return }
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
            var tickCount = 0
            while !Task.isCancelled {
                if let self = self {
                    let sseActive = await self.isSSEActive()
                    if !sseActive {
                        await self.pollRemoteActivity()
                    }
                    tickCount += 1
                    // Periodic auto-eviction pass every hour (720 ticks * 5s = 3600s)
                    if tickCount >= 720 {
                        tickCount = 0
                        _ = await self.evictInactivePlaceholders(olderThanDays: 7)
                    }
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

    public func isSSEActive() -> Bool {
        return isSSEConnected
    }

    public func startRealtimeEventListener() {
        guard !isSSEListening else { return }
        isSSEListening = true
        NSLog("[ZeroDrive] Starting FileProvider real-time SSE event listener")
        sseTask = Task { [weak self] in
            await self?.runSSELoop()
        }
    }

    public func stopRealtimeEventListener() {
        sseTask?.cancel()
        sseTask = nil
        isSSEListening = false
        isSSEConnected = false
        NSLog("[ZeroDrive] Stopped FileProvider real-time SSE event listener")
    }

    private func runSSELoop() async {
        var backoffSeconds: Double = 1.0
        let minBackoffSeconds: Double = 1.0
        let maxBackoffSeconds: Double = 32.0

        while !Task.isCancelled {
            do {
                NSLog("[ZeroDrive] Connecting to real-time SSE stream at /v1/events...")
                try await consumeSSEStream()
                // If stream finishes without throwing
                self.isSSEConnected = false
                backoffSeconds = minBackoffSeconds
                NSLog("[ZeroDrive] SSE stream disconnected cleanly. Reconnecting in %.1fs...", backoffSeconds)
            } catch {
                self.isSSEConnected = false
                if Task.isCancelled { break }
                NSLog("[ZeroDrive] SSE stream disconnected: %@. Retrying in %.1fs (fallback poller active)...", error.localizedDescription, backoffSeconds)
            }

            do {
                try await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
            } catch {
                break
            }
            backoffSeconds = min(backoffSeconds * 2.0, maxBackoffSeconds)
        }

        self.isSSEConnected = false
        self.isSSEListening = false
        NSLog("[ZeroDrive] Terminated FileProvider real-time SSE event listener")
    }

    private func consumeSSEStream() async throws {
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
        guard let url = URL(string: "\(cleanEndpoint)/v1/events") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("ZeroDrive-FileProvider-SSE/3.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 86400

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard httpResponse.statusCode == 200 else {
            throw NSError(
                domain: "ZeroDriveSSE",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode) from SSE endpoint"]
            )
        }

        self.isSSEConnected = true
        NSLog("[ZeroDrive] Real-time SSE connection established with %@", url.absoluteString)

        var currentEvent = "message"
        var currentData = ""

        for try await line in asyncBytes.lines {
            if Task.isCancelled { break }

            if line.hasPrefix(":") {
                // Heartbeat / ping comment
                continue
            } else if line.hasPrefix("event:") {
                if !currentData.isEmpty {
                    await handleIncomingSSEMessage(event: currentEvent, data: currentData)
                    currentData = ""
                }
                let raw = line.dropFirst(6)
                currentEvent = raw.hasPrefix(" ") ? String(raw.dropFirst()) : String(raw)
            } else if line.hasPrefix("data:") {
                let raw = line.dropFirst(5)
                let chunk = raw.hasPrefix(" ") ? String(raw.dropFirst()) : String(raw)
                let trimmed = currentData.trimmingCharacters(in: .whitespacesAndNewlines)
                if !currentData.isEmpty && trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
                    await handleIncomingSSEMessage(event: currentEvent, data: currentData)
                    currentEvent = "message"
                    currentData = chunk
                } else if currentData.isEmpty {
                    currentData = chunk
                } else {
                    currentData += "\n" + chunk
                }
            } else if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !currentData.isEmpty || currentEvent != "message" {
                    await handleIncomingSSEMessage(event: currentEvent, data: currentData)
                    currentEvent = "message"
                    currentData = ""
                }
            }
        }

        if !currentData.isEmpty {
            await handleIncomingSSEMessage(event: currentEvent, data: currentData)
        }
    }

    private func handleIncomingSSEMessage(event: String, data: String) async {
        guard let jsonData = data.data(using: .utf8) else { return }

        struct SSEChangePayload: Codable {
            let path: String?
            let action: String?
            let source: String?
            let destination: String?
            let id: String?
            let timestamp: String?
            let activity: SSEActivityNested?

            struct SSEActivityNested: Codable {
                let path: String?
                let action: String?
                let source: String?
                let destination: String?
                let id: String?
                let timestamp: String?
            }
        }

        guard let payload = try? JSONDecoder().decode(SSEChangePayload.self, from: jsonData) else {
            NSLog("[ZeroDrive] SSE received unparsable payload: event=%@ data=%@", event, data)
            return
        }

        let rawPath = payload.path ?? payload.activity?.path
        let rawAction = payload.action ?? payload.activity?.action
        let rawSource = payload.source ?? payload.activity?.source
        let rawDestination = payload.destination ?? payload.activity?.destination
        let eventId = payload.id ?? payload.activity?.id
        let eventTs = payload.timestamp ?? payload.activity?.timestamp

        let normalizedEvent = event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedAction = (rawAction ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let changeEvents: Set<String> = [
            "change", "write", "delete", "move", "copy", "create_file", "write_file", "delete_file", "move_file", "copy_file", "edit_file"
        ]
        let changeActions: Set<String> = [
            "write", "delete", "move", "copy", "create", "edit", "create_file", "write_file", "delete_file", "move_file", "copy_file", "edit_file"
        ]

        let isChangeEvent = changeEvents.contains(normalizedEvent) ||
                            changeActions.contains(normalizedAction) ||
                            (normalizedEvent == "message" && (rawPath != nil || rawDestination != nil))

        guard isChangeEvent else { return }

        let affectedPaths = [rawPath, rawDestination, rawSource].compactMap { $0 }.filter { !$0.isEmpty }
        if !affectedPaths.isEmpty {
            await RcloneDaemonSupervisor.shared.refreshVFSForRemoteChange(paths: affectedPaths)
        }

        if let id = eventId {
            seenActivityIds.insert(id)
        }
        if let ts = eventTs {
            if lastPolledTimestamp == nil || ts > lastPolledTimestamp! {
                lastPolledTimestamp = ts
            }
        }

        var containersToSignal: Set<NSFileProviderItemIdentifier> = []
        if let p = rawPath, !p.isEmpty {
            containersToSignal.insert(parentContainerIdentifier(for: p))
        }
        if let dst = rawDestination, !dst.isEmpty {
            containersToSignal.insert(parentContainerIdentifier(for: dst))
        }
        if let src = rawSource, !src.isEmpty {
            containersToSignal.insert(parentContainerIdentifier(for: src))
        }
        if containersToSignal.isEmpty {
            containersToSignal.insert(.rootContainer)
        }

        NSLog("[ZeroDrive] Real-time SSE change event: event=%@ action=%@ path=%@ containers=%@",
              event,
              normalizedAction,
              rawPath ?? rawDestination ?? "",
              containersToSignal.map { $0.rawValue }.joined(separator: ", "))

        let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: "ZeroDrive")

        for parentIdentifier in containersToSignal {
            do {
                try await NSFileProviderManager(for: domain)?.signalEnumerator(for: parentIdentifier)
                NSLog("[ZeroDrive] Real-time SSE signaled FileProvider for parent container: %@", parentIdentifier.rawValue)
            } catch {
                NSLog("[ZeroDrive] Real-time SSE signalEnumerator failed for %@: %@", parentIdentifier.rawValue, error.localizedDescription)
            }
        }

        if !containersToSignal.contains(.rootContainer) {
            do {
                try await NSFileProviderManager(for: domain)?.signalEnumerator(for: .rootContainer)
            } catch {}
        }

        do {
            try await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
            NSLog("[ZeroDrive] Real-time SSE signaled FileProvider for workingSet")
        } catch {
            NSLog("[ZeroDrive] Real-time SSE signalEnumerator workingSet notice: %@", error.localizedDescription)
        }
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
            var affectedPaths: [String] = []

            for act in newActivities {
                guard relevantActions.contains(act.action) else { continue }
                NSLog("[ZeroDrive] Remote delta activity detected: action=%@, path=%@", act.action, act.path ?? act.destination ?? act.source ?? "")

                if let p = act.path, !p.isEmpty {
                    containersToSignal.insert(parentContainerIdentifier(for: p))
                    affectedPaths.append(p)
                }
                if let dst = act.destination, !dst.isEmpty {
                    containersToSignal.insert(parentContainerIdentifier(for: dst))
                    affectedPaths.append(dst)
                }
                if let src = act.source, !src.isEmpty {
                    containersToSignal.insert(parentContainerIdentifier(for: src))
                    affectedPaths.append(src)
                }
            }

            if !affectedPaths.isEmpty {
                await RcloneDaemonSupervisor.shared.refreshVFSForRemoteChange(paths: affectedPaths)
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

    // MARK: - Smart Disk Auto-Eviction & Dehydration

    /// Evicts inactive file placeholders back to 0-byte APFS dataless placeholders
    /// that haven't been accessed in `olderThanDays` (default 7 days).
    /// Keeps files visible in Finder while immediately reclaiming local SSD space.
    @discardableResult
    public func evictInactivePlaceholders(olderThanDays: Int = 7) async -> [String] {
        let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: "ZeroDrive")
        guard let manager = NSFileProviderManager(for: domain) else {
            NSLog("[ZeroDrive] NSFileProviderManager unavailable for domain: %@", domainIdentifier.rawValue)
            return []
        }

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        var rootURLs: [URL] = [
            homeDir.appendingPathComponent("Library/CloudStorage/ZeroDrive")
        ]

        if let userVisibleURL = try? await manager.getUserVisibleURL(for: .rootContainer) {
            if !rootURLs.contains(where: { $0.path == userVisibleURL.path }) {
                rootURLs.append(userVisibleURL)
            }
        }

        let cutoffDate = Date().addingTimeInterval(-Double(olderThanDays) * 86400)
        var evictedIdentifiers: [String] = []

        for rootURL in rootURLs {
            guard FileManager.default.fileExists(atPath: rootURL.path) else { continue }

            let resourceKeys: Set<URLResourceKey> = [
                .isRegularFileKey,
                .contentAccessDateKey,
                .contentModificationDateKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .fileSizeKey
            ]

            guard let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            ) else { continue }

            let fileURLs = enumerator.compactMap { $0 as? URL }
            for fileURL in fileURLs {
                do {
                    let values = try fileURL.resourceValues(forKeys: resourceKeys)
                    guard values.isRegularFile == true else { continue }

                    // Only evict files consuming physical blocks on the APFS volume
                    let allocatedBytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
                    guard allocatedBytes > 0 else { continue }

                    // Check last access date, falling back to modification date
                    let lastAccess = values.contentAccessDate ?? values.contentModificationDate ?? Date.distantPast
                    if lastAccess < cutoffDate {
                        let basePath = rootURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        let fullPath = fileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        var relPath = fullPath
                        if fullPath.hasPrefix(basePath + "/") {
                            relPath = String(fullPath.dropFirst(basePath.count + 1))
                        }
                        let itemIdentifier = NSFileProviderItemIdentifier(relPath)

                        do {
                            try await manager.evictItem(withIdentifier: itemIdentifier)
                            evictedIdentifiers.append(relPath)
                            NSLog("[ZeroDrive] Evicted inactive placeholder: %@ (reclaimed %lld bytes)", relPath, Int64(allocatedBytes))
                        } catch {
                            NSLog("[ZeroDrive] Evict item %@ notice: %@", relPath, error.localizedDescription)
                        }
                    }
                } catch {
                    continue
                }
            }
        }

        if !evictedIdentifiers.isEmpty {
            NSLog("[ZeroDrive] Eviction complete. Reclaimed local SSD space for %ld files older than %ld days.", evictedIdentifiers.count, olderThanDays)
        }
        return evictedIdentifiers
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

    // MARK: - Multi-Drive Domain Management

    /// Adds a new FileProvider domain for a secondary or named drive
    public func addDriveDomain(name: String, identifier: String) async throws {
        let domainId = NSFileProviderDomainIdentifier(identifier)
        let domain = NSFileProviderDomain(identifier: domainId, displayName: name)
        try await NSFileProviderManager.add(domain)
        NSLog("[ZeroDrive] Added FileProvider domain '%@' (id: %@)", name, identifier)
    }

    /// Removes a FileProvider domain by its identifier
    public func removeDriveDomain(identifier: String) async throws {
        let domainId = NSFileProviderDomainIdentifier(identifier)
        let domains = await listDriveDomains()
        if let existing = domains.first(where: { $0.identifier == domainId }) {
            try await NSFileProviderManager.remove(existing)
            NSLog("[ZeroDrive] Successfully removed FileProvider domain '%@'", identifier)
        } else {
            let domain = NSFileProviderDomain(identifier: domainId, displayName: identifier)
            try await NSFileProviderManager.remove(domain)
            NSLog("[ZeroDrive] Removed FileProvider domain by identifier '%@'", identifier)
        }
    }

    /// Lists all currently registered FileProvider domains
    public func listDriveDomains() async -> [NSFileProviderDomain] {
        do {
            return try await NSFileProviderManager.domains()
        } catch {
            NSLog("[ZeroDrive] Error listing FileProvider domains: %@", error.localizedDescription)
            return []
        }
    }
}

// MARK: - NSFileProviderManager Eviction Compatibility Extension
extension NSFileProviderManager {
    /// Convenience async wrapper enabling evictItem(withIdentifier:) parameter naming
    public func evictItem(withIdentifier itemIdentifier: NSFileProviderItemIdentifier) async throws {
        try await self.evictItem(identifier: itemIdentifier)
    }
}
