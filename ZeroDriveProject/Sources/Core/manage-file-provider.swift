import Foundation
import FileProvider

/// Coordinates real-time cloud change streams (SSE `/v1/events` + `/v1/activity` delta fallback)
/// for the ZeroDrive Direct Streaming Drive (`~/ZeroDrive`), and retires any legacy FileProvider domains
/// so duplicate background XPC sync extensions never compete with `~/ZeroDrive`.
public actor ManageFileProvider {
    public static let shared = ManageFileProvider()

    private let appGroupIdentifier = "group.co.aisimple.zerodrive"

    private var pollerTask: Task<Void, Never>?
    private var sseTask: Task<Void, Never>?
    private var lastPolledTimestamp: String?
    private var seenActivityIds: Set<String> = []
    private var isPolling = false
    private var isSSEListening = false
    private var isSSEConnected = false
    private var hasCleanedLegacyDomains = false

    public func syncCredentialsToAppGroup(
        endpoint: String? = nil,
        token: String? = nil
    ) {
        let resolved = MultiCloudCombineBuilder.shared.resolveActiveApiCredentials()
        let finalEndpoint = endpoint ?? resolved?.endpoint ?? "https://api.zerodrive.dev"
        let finalToken = token ?? resolved?.token ?? ""
        guard !finalToken.isEmpty else { return }

        if let groupDefaults = UserDefaults(suiteName: appGroupIdentifier) {
            groupDefaults.set(finalEndpoint, forKey: "api_endpoint")
            groupDefaults.set(finalToken, forKey: "api_token")
        }
    }

    /// Starts the live SSE + delta sync stream for `~/ZeroDrive` immediately,
    /// and retires any legacy FileProvider extension asynchronously without blocking XPC.
    public func registerDomainIfNeeded() async {
        syncCredentialsToAppGroup()
        startBackgroundPoller()
        startRealtimeEventListener()
        retireLegacyFileProviderDomainsIfNeeded()
    }

    /// Forces an immediate delta check and fresh SSE stream after waking from macOS sleep
    public func restartEventStreamAfterWake() async {
        stopRealtimeEventListener()
        await pollRemoteActivity()
        startRealtimeEventListener()
    }

    private func retireLegacyFileProviderDomainsIfNeeded() {
        guard !hasCleanedLegacyDomains else { return }
        hasCleanedLegacyDomains = true

        // Disable legacy FileProvider extension registration in PlugInKit without blocking startup or XPC
        DispatchQueue.global(qos: .utility).async {
            let pk = Process()
            pk.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            pk.arguments = ["-e", "ignore", "-i", "co.aisimple.zerodrive.fileprovider"]
            pk.standardOutput = FileHandle.nullDevice
            pk.standardError = FileHandle.nullDevice
            try? pk.run()
            pk.waitUntilExit()

            // Only touch NSFileProviderManager if the legacy appex bundle is actually present on disk;
            // calling NSFileProviderManager.domains() without an embedded FileProvider appex hangs XPC indefinitely!
            if let plugInsURL = Bundle.main.builtInPlugInsURL,
               FileManager.default.fileExists(atPath: plugInsURL.appendingPathComponent("ZeroDriveFileProvider.appex").path) {
                Task.detached(priority: .background) {
                    if let existingDomains = try? await NSFileProviderManager.domains(), !existingDomains.isEmpty {
                        for domain in existingDomains {
                            try? await NSFileProviderManager.remove(domain)
                        }
                    }
                }
            }
        }
    }

    public func startBackgroundPoller(intervalSeconds: Double = 10.0) {
        guard !isPolling else { return }
        isPolling = true
        pollerTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self = self {
                    let sseActive = await self.isSSEActive()
                    if !sseActive {
                        await self.pollRemoteActivity()
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
    }

    public func isSSEActive() -> Bool {
        return isSSEConnected
    }

    public func startRealtimeEventListener() {
        guard !isSSEListening else { return }
        isSSEListening = true
        sseTask = Task { [weak self] in
            await self?.runSSELoop()
        }
    }

    public func stopRealtimeEventListener() {
        sseTask?.cancel()
        sseTask = nil
        isSSEListening = false
        isSSEConnected = false
    }

    private func resolveCredentials() -> (endpoint: String, token: String)? {
        if let live = MultiCloudCombineBuilder.shared.resolveActiveApiCredentials() {
            return live
        }
        if let groupDefaults = UserDefaults(suiteName: appGroupIdentifier),
           let ep = groupDefaults.string(forKey: "api_endpoint"), !ep.isEmpty,
           let tok = groupDefaults.string(forKey: "api_token"), !tok.isEmpty {
            return (endpoint: ep, token: tok)
        }
        return nil
    }

    private func runSSELoop() async {
        var backoffSeconds: Double = 1.5
        let minBackoffSeconds: Double = 1.5
        let maxBackoffSeconds: Double = 30.0

        while !Task.isCancelled {
            guard let creds = resolveCredentials() else {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                continue
            }

            do {
                try await consumeSSEStream(endpoint: creds.endpoint, token: creds.token)
                self.isSSEConnected = false
                backoffSeconds = minBackoffSeconds
            } catch {
                self.isSSEConnected = false
                if Task.isCancelled { break }
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
    }

    private func consumeSSEStream(endpoint: String, token: String) async throws {
        let cleanEndpoint = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(cleanEndpoint)/v1/events") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("ZeroDrive-DirectDrive-SSE/3.2", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 86400

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(
                domain: "ZeroDriveSSE",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(status) from SSE endpoint"]
            )
        }

        self.isSSEConnected = true
        NSLog("[ZeroDrive] Live SSE push connected to %@", url.absoluteString)

        var currentEvent = "message"
        var currentData = ""

        for try await line in asyncBytes.lines {
            if Task.isCancelled { break }

            if line.hasPrefix(":") {
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

        if let id = eventId {
            seenActivityIds.insert(id)
        }
        if let ts = eventTs, lastPolledTimestamp == nil || ts > lastPolledTimestamp! {
            lastPolledTimestamp = ts
        }

        let affectedPaths = [rawPath, rawDestination, rawSource].compactMap { $0 }.filter { !$0.isEmpty }
        if !affectedPaths.isEmpty {
            await RcloneDaemonSupervisor.shared.refreshVFSForRemoteChange(paths: affectedPaths)
        }
    }

    public func pollRemoteActivity() async {
        guard let creds = resolveCredentials() else { return }
        let cleanEndpoint = creds.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(cleanEndpoint)/v1/activity?limit=50") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        request.setValue("ZeroDrive-DirectDrive-Poller/3.2", forHTTPHeaderField: "User-Agent")
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

            if lastPolledTimestamp == nil {
                if let latest = decoded.activities.first {
                    lastPolledTimestamp = latest.timestamp
                    seenActivityIds = Set(decoded.activities.map { $0.id })
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
                return lastTs.isEmpty ? true : (act.timestamp >= lastTs)
            }

            guard !newActivities.isEmpty else { return }

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

            var affectedPaths: [String] = []
            for act in newActivities where relevantActions.contains(act.action) {
                if let p = act.path, !p.isEmpty { affectedPaths.append(p) }
                if let dst = act.destination, !dst.isEmpty { affectedPaths.append(dst) }
                if let src = act.source, !src.isEmpty { affectedPaths.append(src) }
            }

            if !affectedPaths.isEmpty {
                await RcloneDaemonSupervisor.shared.refreshVFSForRemoteChange(paths: affectedPaths)
            }
        } catch {}
    }

    // MARK: - Multi-Drive Compatibility Hooks (Secondary drives mount inside ~/ZeroDrive/<DriveName>)

    public func addDriveDomain(name: String, identifier: String) async throws {
        // Secondary drives mount directly inside ~/ZeroDrive/<Name> via MultiCloudCombineBuilder
    }

    public func removeDriveDomain(identifier: String) async throws {
        let domainId = NSFileProviderDomainIdentifier(identifier)
        if let domains = try? await NSFileProviderManager.domains(),
           let existing = domains.first(where: { $0.identifier == domainId }) {
            try? await NSFileProviderManager.remove(existing)
        }
    }
}
