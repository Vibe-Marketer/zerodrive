import Foundation
import SwiftUI
import AppKit
import CryptoKit

public struct ReleaseEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: String { version }
    public let version: String
    public let build: String?
    public let date: String
    public let title: String
    public let summary: String?
    public let highlights: [String]
    public let notes_markdown: String
    public let mandatory: Bool?
    public let min_supported_version: String?

    public init(
        version: String,
        build: String? = nil,
        date: String,
        title: String,
        summary: String? = nil,
        highlights: [String] = [],
        notes_markdown: String = "",
        mandatory: Bool? = false,
        min_supported_version: String? = "1.0.0"
    ) {
        self.version = version
        self.build = build
        self.date = date
        self.title = title
        self.summary = summary
        self.highlights = highlights
        self.notes_markdown = notes_markdown
        self.mandatory = mandatory
        self.min_supported_version = min_supported_version
    }
}

public struct PlatformArtifactInfo: Codable, Equatable, Sendable {
    public let platform: String
    public let arch: String?
    public let filename: String
    public let url: String
    public let dmg_url: String?
    public let size: Int64
    public let sha256: String
    public let signature: String
    public let signature_alg: String?
    public let signed_payload: String?
    public let team_id: String?
    public let notarized: Bool?
    public let minimum_os: String?
}

public struct ReleaseCheckResponse: Codable, Sendable {
    public let ok: Bool
    public let platform: String?
    public let current_version: String?
    public let latest_version: String
    public let update_available: Bool
    public let mandatory: Bool?
    public let latest: ReleaseEntry?
    public let platform_artifact: PlatformArtifactInfo?
    public let missed_releases: [ReleaseEntry]?
    public let combined_notes_markdown: String?
    public let all_releases: [ReleaseEntry]?
    public let public_key: String?
    public let checked_at: String?
}

public struct ChangelogFeedResponse: Codable, Sendable {
    public let ok: Bool
    public let latest_version: String?
    public let releases: [ReleaseEntry]
    public let all_releases: [ReleaseEntry]?
    public let markdown: String?
}

private struct BundledReleaseNotesPayload: Codable {
    let latest_version: String?
    let releases: [ReleaseEntry]
}

private struct UpdatePersistentState: Codable {
    var lastLaunchedVersion: String?
    var previousVersion: String?
    var pendingUpdateFromVersion: String?
    var deferredVersion: String?
    var deferredUntil: Date?
    var lastCheckedAt: Date?
    var lastSeenChangelogVersion: String?
}

public enum UpdateCheckTrigger: String, Sendable {
    case launch
    case login
    case periodic
    case manual
}

@MainActor
public final class ManageAppUpdates: ObservableObject {
    public static let shared = ManageAppUpdates()

    public nonisolated static let expectedTeamID = "DTB456HJMJ"
    public nonisolated static let expectedBundleID = "co.aisimple.zerodrive"
    public nonisolated static let embeddedPublicKeyPEM = """
    -----BEGIN PUBLIC KEY-----
    MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE/JM4b2aY9Rt903bl8CDZt3kbcV5c
    I75mfIZAxtzNsSuNxNVLGvRoZ3kwUZ5UtigFOmBfoFkAtA4CgBRi+q9OMQ==
    -----END PUBLIC KEY-----
    """

    @Published public private(set) var currentVersion: String
    @Published public private(set) var currentBuild: String
    @Published public private(set) var isChecking: Bool = false
    @Published public private(set) var updateAvailable: Bool = false
    @Published public private(set) var latestRelease: ReleaseEntry? = nil
    @Published public private(set) var platformArtifact: PlatformArtifactInfo? = nil
    @Published public private(set) var missedReleases: [ReleaseEntry] = []
    @Published public private(set) var allReleases: [ReleaseEntry] = []
    @Published public private(set) var publicKeyPEM: String = ManageAppUpdates.embeddedPublicKeyPEM

    @Published public private(set) var isDownloading: Bool = false
    @Published public private(set) var isInstalling: Bool = false
    @Published public private(set) var downloadProgress: Double = 0.0
    @Published public private(set) var downloadedBytes: Int64 = 0
    @Published public private(set) var totalBytes: Int64 = 0
    @Published public private(set) var statusMessage: String = ""
    @Published public private(set) var errorMessage: String = ""
    @Published public private(set) var lastCheckedAt: Date? = nil
    @Published public private(set) var isUpToDateNotice: Bool = false

    @Published public var showUpdatePromptSheet: Bool = false
    @Published public var showChangelogSheet: Bool = false
    @Published public private(set) var justUpdatedFromVersion: String? = nil

    @Published public var autoCheckEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoCheckEnabled, forKey: "zerodrive_auto_check_updates")
            if autoCheckEnabled {
                schedulePeriodicTimer()
            } else {
                periodicTimer?.invalidate()
                periodicTimer = nil
            }
        }
    }

    private var periodicTimer: Timer? = nil
    private var activeDownloadTask: Task<Void, Never>? = nil
    private var hasStartedLifecycle: Bool = false
    private let checkIntervalSeconds: TimeInterval = 4 * 3600 // 4 hours

    private var apiBaseURL: String {
        if let env = ProcessInfo.processInfo.environment["ZERODRIVE_UPDATE_ENDPOINT"], !env.isEmpty {
            return env.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return "https://api.zerodrive.dev"
    }

    private var stateFileURL: URL {
        if let custom = ProcessInfo.processInfo.environment["ZERODRIVE_UPDATE_STATE_PATH"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/rclone/zerodrive-update-state.json")
    }

    private var updatesCacheDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zerodrive-cache/updates")
    }

    private init() {
        let info = Bundle.main.infoDictionary
        self.currentVersion = (info?["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "3.0.0"
        self.currentBuild = (info?["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "1"
        if UserDefaults.standard.object(forKey: "zerodrive_auto_check_updates") == nil {
            UserDefaults.standard.set(true, forKey: "zerodrive_auto_check_updates")
        }
        self.autoCheckEnabled = UserDefaults.standard.bool(forKey: "zerodrive_auto_check_updates")
        let state = loadState()
        self.lastCheckedAt = state.lastCheckedAt
        loadBundledChangelog()
    }

    // MARK: - Semver Helpers

    public nonisolated static func parseSemver(_ raw: String) -> (major: Int, minor: Int, patch: Int) {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: [.regularExpression, .caseInsensitive])
            .split(separator: "+", maxSplits: 1).first.map(String.init) ?? "0.0.0"
        let core = cleaned.split(separator: "-", maxSplits: 1).first.map(String.init) ?? cleaned
        let parts = core.split(separator: ".").map { part -> Int in
            let digits = part.filter { $0.isNumber }
            return Int(digits) ?? 0
        }
        let major = parts.count > 0 ? parts[0] : 0
        let minor = parts.count > 1 ? parts[1] : 0
        let patch = parts.count > 2 ? parts[2] : 0
        return (major, minor, patch)
    }

    public nonisolated static func compareSemver(_ a: String, _ b: String) -> Int {
        let pa = parseSemver(a)
        let pb = parseSemver(b)
        if pa.major != pb.major { return pa.major > pb.major ? 1 : -1 }
        if pa.minor != pb.minor { return pa.minor > pb.minor ? 1 : -1 }
        if pa.patch != pb.patch { return pa.patch > pb.patch ? 1 : -1 }
        return 0
    }

    // MARK: - Lifecycle & Post-Update Changelog

    public func startAutomaticLifecycle() {
        guard !hasStartedLifecycle else { return }
        hasStartedLifecycle = true

        loadBundledChangelog()
        detectAndPresentPostUpdateChangelog()
        schedulePeriodicTimer()

        if autoCheckEnabled {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await self?.checkForUpdates(trigger: .launch)
            }
        }
    }

    public func handleSystemWake() {
        guard autoCheckEnabled else { return }
        if let last = lastCheckedAt, Date().timeIntervalSince(last) < checkIntervalSeconds {
            return
        }
        Task { [weak self] in
            await self?.checkForUpdates(trigger: .periodic)
        }
    }

    private func schedulePeriodicTimer() {
        periodicTimer?.invalidate()
        guard autoCheckEnabled else { return }
        periodicTimer = Timer.scheduledTimer(withTimeInterval: checkIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkForUpdates(trigger: .periodic)
            }
        }
    }

    private func detectAndPresentPostUpdateChangelog() {
        var state = loadState()
        let prevFromPending = state.pendingUpdateFromVersion
        let prevFromLastLaunch = state.lastLaunchedVersion

        let previousVersion: String?
        if let pending = prevFromPending, Self.compareSemver(currentVersion, pending) > 0 {
            previousVersion = pending
        } else if let last = prevFromLastLaunch, Self.compareSemver(currentVersion, last) > 0 {
            previousVersion = last
        } else {
            previousVersion = nil
        }

        state.lastLaunchedVersion = currentVersion
        state.pendingUpdateFromVersion = nil

        if let prev = previousVersion {
            state.previousVersion = prev
            state.lastSeenChangelogVersion = currentVersion
            saveState(state)

            self.justUpdatedFromVersion = prev
            self.missedReleases = computeLocalMissedReleases(fromVersion: prev, toVersion: currentVersion)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.showChangelogSheet = true
            }
        } else {
            saveState(state)
        }
    }

    private func loadBundledChangelog() {
        if let bundledURL = Bundle.main.url(forResource: "release-notes", withExtension: "json"),
           let data = try? Data(contentsOf: bundledURL),
           let payload = try? JSONDecoder().decode(BundledReleaseNotesPayload.self, from: data),
           !payload.releases.isEmpty {
            self.allReleases = payload.releases.sorted { Self.compareSemver($0.version, $1.version) > 0 }
            return
        }

        // Embedded fallback for developer builds where release-notes.json wasn't bundled yet
        self.allReleases = [
            ReleaseEntry(
                version: currentVersion,
                build: currentBuild,
                date: "2026-11-13",
                title: "ZeroDrive Desktop",
                summary: "Automatic updates, verified releases, and in-app changelog.",
                highlights: [
                    "Automatic background update checks on launch, sign-in, and every 4 hours",
                    "Signed releases with SHA-256 + ECDSA P-256 cryptographic verification"
                ],
                notes_markdown: "- Automatic background update checks on launch, sign-in, and every 4 hours\n- Signed releases with SHA-256 + ECDSA P-256 cryptographic verification"
            )
        ]
    }

    public func computeLocalMissedReleases(fromVersion: String?, toVersion: String) -> [ReleaseEntry] {
        let sorted = allReleases.sorted { Self.compareSemver($0.version, $1.version) > 0 }
        return sorted.filter { rel in
            let gtFrom = fromVersion.map { Self.compareSemver(rel.version, $0) > 0 } ?? true
            let lteTo = Self.compareSemver(rel.version, toVersion) <= 0
            return gtFrom && lteTo
        }
    }

    public func openChangelog() {
        Task {
            await refreshChangelogFromServer()
        }
        showChangelogSheet = true
    }

    public func refreshChangelogFromServer() async {
        guard let url = URL(string: "\(apiBaseURL)/v1/releases/changelog") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                let decoded = try JSONDecoder().decode(ChangelogFeedResponse.self, from: data)
                let list = decoded.all_releases ?? decoded.releases
                if !list.isEmpty {
                    self.allReleases = list.sorted { Self.compareSemver($0.version, $1.version) > 0 }
                    if let prev = justUpdatedFromVersion {
                        self.missedReleases = computeLocalMissedReleases(fromVersion: prev, toVersion: currentVersion)
                    }
                }
            }
        } catch {
            // Keep bundled changelog silently when offline
        }
    }

    // MARK: - Update Checking

    public func checkForUpdates(trigger: UpdateCheckTrigger) async {
        if isChecking || isDownloading || isInstalling { return }

        isChecking = true
        isUpToDateNotice = false
        if trigger == .manual {
            errorMessage = ""
            statusMessage = "Checking for updates…"
        }

        defer { isChecking = false }

        var comps = URLComponents(string: "\(apiBaseURL)/v1/releases/latest")
        comps?.queryItems = [
            URLQueryItem(name: "platform", value: "macos"),
            URLQueryItem(name: "current_version", value: currentVersion),
            URLQueryItem(name: "arch", value: "arm64")
        ]

        guard let url = comps?.url else {
            if trigger == .manual {
                errorMessage = "Invalid update server URL."
            }
            return
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                if trigger == .manual {
                    errorMessage = "Update service returned an unexpected response. Your current version continues working normally."
                    statusMessage = ""
                }
                return
            }

            let decoded = try JSONDecoder().decode(ReleaseCheckResponse.self, from: data)
            let now = Date()
            self.lastCheckedAt = now
            var state = loadState()
            state.lastCheckedAt = now
            saveState(state)

            if let pk = decoded.public_key, !pk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.publicKeyPEM = pk
            }
            if let all = decoded.all_releases, !all.isEmpty {
                self.allReleases = all.sorted { Self.compareSemver($0.version, $1.version) > 0 }
            }

            let serverHasNewer = Self.compareSemver(decoded.latest_version, currentVersion) > 0 && decoded.update_available
            self.updateAvailable = serverHasNewer
            self.latestRelease = decoded.latest
            self.platformArtifact = decoded.platform_artifact
            self.missedReleases = decoded.missed_releases ?? computeLocalMissedReleases(fromVersion: currentVersion, toVersion: decoded.latest_version)

            if serverHasNewer {
                statusMessage = "ZeroDrive v\(decoded.latest_version) is available."
                if shouldPresentPrompt(forVersion: decoded.latest_version, trigger: trigger, state: state) {
                    self.showUpdatePromptSheet = true
                }
            } else {
                isUpToDateNotice = true
                statusMessage = "You're up to date (v\(currentVersion))."
                if trigger == .manual {
                    // Don't pop update sheet if up-to-date; settings/feedback shows it clearly
                    self.showUpdatePromptSheet = false
                }
            }
        } catch {
            // Failure case: offline or transient outage — stay silent on automatic checks
            if trigger == .manual {
                errorMessage = "Could not reach update server (you appear to be offline). Current version v\(currentVersion) remains active."
                statusMessage = ""
            }
        }
    }

    private func shouldPresentPrompt(forVersion version: String, trigger: UpdateCheckTrigger, state: UpdatePersistentState) -> Bool {
        if trigger == .manual {
            return true
        }
        if let deferredVer = state.deferredVersion,
           deferredVer == version,
           let until = state.deferredUntil,
           Date() < until {
            return false
        }
        return true
    }

    public func deferCurrentUpdate() {
        var state = loadState()
        state.deferredVersion = latestRelease?.version
        state.deferredUntil = Date().addingTimeInterval(24 * 3600)
        saveState(state)
        showUpdatePromptSheet = false
        if let ver = latestRelease?.version {
            statusMessage = "Update v\(ver) deferred — you can install anytime from Dashboard or Settings."
        }
    }

    public func cancelDownload() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        isDownloading = false
        statusMessage = "Download paused. Partial file saved so you can resume anytime."
    }

    // MARK: - Download, Cryptographic Verify & Atomic Install

    public func startDownloadAndInstall() {
        guard !isDownloading && !isInstalling else { return }
        activeDownloadTask = Task { [weak self] in
            await self?.downloadAndInstallUpdate()
        }
    }

    public func downloadAndInstallUpdate(targetAppOverride: URL? = nil, skipRelaunch: Bool = false) async {
        guard let artifact = platformArtifact,
              let release = latestRelease,
              let downloadURL = URL(string: artifact.url) else {
            errorMessage = "Missing update download metadata. Please check for updates again."
            return
        }

        errorMessage = ""
        isDownloading = true
        downloadProgress = 0.0
        downloadedBytes = 0
        totalBytes = artifact.size
        statusMessage = "Preparing download for ZeroDrive v\(release.version)…"

        do {
            try FileManager.default.createDirectory(at: updatesCacheDir, withIntermediateDirectories: true)
            let partURL = updatesCacheDir.appendingPathComponent("\(artifact.filename).part")
            let verifiedZipURL = updatesCacheDir.appendingPathComponent(artifact.filename)

            // 1. Download with HTTP Range resume & retry
            try await downloadFileWithResume(
                from: downloadURL,
                toPartFile: partURL,
                expectedSize: artifact.size
            )

            if Task.isCancelled {
                isDownloading = false
                return
            }

            isDownloading = false
            isInstalling = true
            statusMessage = "Verifying cryptographic signature & SHA-256 checksum…"

            // 2. Cryptographic & Size Verification
            try Self.verifyDownloadedArtifact(
                fileURL: partURL,
                platform: "macos",
                version: release.version,
                expectedSize: artifact.size,
                expectedSha256: artifact.sha256,
                signatureBase64: artifact.signature,
                publicKeyPEM: publicKeyPEM
            )

            if FileManager.default.fileExists(atPath: verifiedZipURL.path) {
                try? FileManager.default.removeItem(at: verifiedZipURL)
            }
            try FileManager.default.moveItem(at: partURL, to: verifiedZipURL)

            // 3. Unpack into isolated staging directory and verify macOS Developer ID signature
            statusMessage = "Verifying Apple Developer ID code signature…"
            let stageDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("zerodrive-update-stage-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
            defer {
                if skipRelaunch {
                    try? FileManager.default.removeItem(at: stageDir)
                }
            }

            let stagedApp = try Self.extractAndVerifyMacAppBundle(zipURL: verifiedZipURL, stageDir: stageDir)

            // 4. Determine destination .app path
            let targetApp: URL = targetAppOverride ?? Self.resolveInstalledAppBundleURL()

            // 5. Flush active spool cleanly if installing live
            if !skipRelaunch && SpoolAndGuardManager.shared.dirtyFileCount > 0 {
                statusMessage = "Flushing \(SpoolAndGuardManager.shared.dirtyFileCount) pending cloud file(s) before restart…"
                await SpoolAndGuardManager.shared.flushQueueImmediately()
            }

            // Record pending update state BEFORE replacing so new version displays What's New automatically
            var state = loadState()
            state.pendingUpdateFromVersion = currentVersion
            state.deferredVersion = nil
            state.deferredUntil = nil
            saveState(state)

            if skipRelaunch {
                // Direct atomic swap for CLI verification mode
                try Self.atomicReplaceAppBundle(stagedApp: stagedApp, targetApp: targetApp)
                isInstalling = false
                statusMessage = "Installed ZeroDrive v\(release.version) atomically at \(targetApp.path)."
                return
            }

            // 6. Launch detached atomic swap & relaunch helper script, then quit current app cleanly
            statusMessage = "Installing ZeroDrive v\(release.version) & restarting…"
            try launchDetachedInstallerAndQuit(stagedApp: stagedApp, targetApp: targetApp, stageDir: stageDir)
        } catch is CancellationError {
            isDownloading = false
            isInstalling = false
            statusMessage = "Download cancelled. Partial download kept for resume."
        } catch {
            isDownloading = false
            isInstalling = false
            // Preserve current running app untouched on any failure
            var state = loadState()
            state.pendingUpdateFromVersion = nil
            saveState(state)
            errorMessage = "Update failed safely (your current v\(currentVersion) remains untouched): \(error.localizedDescription)"
            statusMessage = ""
        }
    }

    private func downloadFileWithResume(from url: URL, toPartFile partURL: URL, expectedSize: Int64) async throws {
        let maxAttempts = 3
        var attempt = 0

        while attempt < maxAttempts {
            try Task.checkCancellation()
            attempt += 1

            let existingSize: Int64
            if FileManager.default.fileExists(atPath: partURL.path),
               let attrs = try? FileManager.default.attributesOfItem(atPath: partURL.path),
               let fileSize = attrs[.size] as? NSNumber {
                existingSize = fileSize.int64Value
            } else {
                existingSize = 0
            }

            if expectedSize > 0 && existingSize == expectedSize {
                downloadedBytes = existingSize
                totalBytes = expectedSize
                downloadProgress = 1.0
                return
            }

            if expectedSize > 0 && existingSize > expectedSize {
                try? FileManager.default.removeItem(at: partURL)
            }

            let effectiveExisting = FileManager.default.fileExists(atPath: partURL.path) ? existingSize : 0

            var req = URLRequest(url: url)
            req.timeoutInterval = 120
            req.cachePolicy = .reloadIgnoringLocalCacheData
            if effectiveExisting > 0 && (expectedSize == 0 || effectiveExisting < expectedSize) {
                req.setValue("bytes=\(effectiveExisting)-", forHTTPHeaderField: "Range")
                statusMessage = "Resuming download from \(ByteCountFormatter.string(fromByteCount: effectiveExisting, countStyle: .file))…"
            } else {
                statusMessage = "Downloading ZeroDrive update…"
            }

            do {
                try await Self.performChunkedDownload(
                    request: req,
                    partURL: partURL,
                    existingSize: effectiveExisting,
                    expectedSize: expectedSize
                ) { [weak self] downloaded, total in
                    Task { @MainActor in
                        guard let self else { return }
                        self.downloadedBytes = downloaded
                        self.totalBytes = total
                        if total > 0 {
                            self.downloadProgress = min(1.0, Double(downloaded) / Double(total))
                        }
                    }
                }
                if expectedSize > 0 {
                    self.downloadedBytes = expectedSize
                    self.totalBytes = expectedSize
                    self.downloadProgress = 1.0
                }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt >= maxAttempts {
                    throw error
                }
                statusMessage = "Connection interrupted — retrying download (attempt \(attempt + 1)/\(maxAttempts))…"
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
            }
        }
    }

    private final class ChunkDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let partURL: URL
        private let existingSize: Int64
        private let expectedSize: Int64
        private let onProgress: @Sendable (Int64, Int64) -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var handle: FileHandle?
        private var currentBytes: Int64 = 0
        private var resolvedTotal: Int64 = 0
        private var lastReportedBytes: Int64 = 0
        private var finished = false
        private var completedWith416 = false
        private var cancelledByCaller = false
        private var explicitError: Error?

        func markCancelled() {
            lock.lock()
            cancelledByCaller = true
            lock.unlock()
        }

        init(
            partURL: URL,
            existingSize: Int64,
            expectedSize: Int64,
            onProgress: @escaping @Sendable (Int64, Int64) -> Void,
            continuation: CheckedContinuation<Void, Error>
        ) {
            self.partURL = partURL
            self.existingSize = existingSize
            self.expectedSize = expectedSize
            self.onProgress = onProgress
            self.continuation = continuation
        }

        private func finishLocked(_ result: Result<Void, Error>) {
            guard !finished else { return }
            finished = true
            try? handle?.close()
            handle = nil
            let cont = continuation
            continuation = nil
            lock.unlock()
            switch result {
            case .success:
                cont?.resume(returning: ())
            case .failure(let error):
                cont?.resume(throwing: error)
            }
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse else {
                lock.lock()
                explicitError = NSError(domain: "ZeroDriveUpdater", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response during download."])
                completionHandler(.cancel)
                finishLocked(.failure(explicitError!))
                return
            }

            if http.statusCode == 416 && expectedSize > 0 && existingSize == expectedSize {
                lock.lock()
                completedWith416 = true
                let finalTotal = expectedSize
                lock.unlock()
                onProgress(existingSize, finalTotal)
                completionHandler(.cancel)
                lock.lock()
                finishLocked(.success(()))
                return
            }

            guard http.statusCode == 200 || http.statusCode == 206 else {
                let err = NSError(domain: "ZeroDriveUpdater", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server returned HTTP \(http.statusCode) while downloading update."])
                lock.lock()
                explicitError = err
                completionHandler(.cancel)
                finishLocked(.failure(err))
                return
            }

            let isResuming = (http.statusCode == 206 && existingSize > 0)
            do {
                if !FileManager.default.fileExists(atPath: partURL.path) || !isResuming {
                    FileManager.default.createFile(atPath: partURL.path, contents: nil)
                }
                let fh = try FileHandle(forUpdating: partURL)
                let startOffset: Int64
                if isResuming {
                    try fh.seekToEnd()
                    startOffset = existingSize
                } else {
                    try fh.truncate(atOffset: 0)
                    startOffset = 0
                }

                let total: Int64
                if expectedSize > 0 {
                    total = expectedSize
                } else if http.expectedContentLength > 0 {
                    total = startOffset + http.expectedContentLength
                } else {
                    total = 0
                }

                lock.lock()
                self.handle = fh
                self.currentBytes = startOffset
                self.resolvedTotal = total
                self.lastReportedBytes = startOffset
                lock.unlock()

                onProgress(startOffset, total)
                completionHandler(.allow)
            } catch {
                lock.lock()
                explicitError = error
                completionHandler(.cancel)
                finishLocked(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            if finished || completedWith416 {
                lock.unlock()
                return
            }
            do {
                try handle?.write(contentsOf: data)
                currentBytes += Int64(data.count)
                let bytesNow = currentBytes
                let totalNow = resolvedTotal
                let shouldReport = (bytesNow - lastReportedBytes) >= 262_144
                if shouldReport {
                    lastReportedBytes = bytesNow
                }
                lock.unlock()
                if shouldReport {
                    onProgress(bytesNow, totalNow)
                }
            } catch {
                explicitError = error
                dataTask.cancel()
                finishLocked(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            if completedWith416 {
                finishLocked(.success(()))
                return
            }
            if let err = explicitError ?? error {
                if cancelledByCaller || (err as NSError).code == NSURLErrorCancelled {
                    finishLocked(.failure(CancellationError()))
                } else {
                    finishLocked(.failure(err))
                }
                return
            }
            let bytesNow = currentBytes
            let totalNow = resolvedTotal
            finishLocked(.success(()))
            onProgress(bytesNow, totalNow)
        }
    }

    private nonisolated static func performChunkedDownload(
        request: URLRequest,
        partURL: URL,
        existingSize: Int64,
        expectedSize: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        final class TaskBox: @unchecked Sendable {
            var task: URLSessionDataTask?
            var delegate: ChunkDownloadDelegate?
        }
        let box = TaskBox()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let delegate = ChunkDownloadDelegate(
                    partURL: partURL,
                    existingSize: existingSize,
                    expectedSize: expectedSize,
                    onProgress: onProgress,
                    continuation: continuation
                )
                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                let dataTask = session.dataTask(with: request)
                box.task = dataTask
                box.delegate = delegate
                dataTask.resume()
                session.finishTasksAndInvalidate()
            }
        } onCancel: {
            box.delegate?.markCancelled()
            box.task?.cancel()
        }
    }

    // MARK: - Cryptographic & Code Signature Verification

    public nonisolated static func verifyDownloadedArtifact(
        fileURL: URL,
        platform: String,
        version: String,
        expectedSize: Int64,
        expectedSha256: String,
        signatureBase64: String,
        publicKeyPEM: String
    ) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw NSError(domain: "ZeroDriveUpdater", code: 10, userInfo: [NSLocalizedDescriptionKey: "Downloaded update file is missing."])
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let actualSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if expectedSize > 0 && actualSize != expectedSize {
            try? FileManager.default.removeItem(at: fileURL)
            throw NSError(domain: "ZeroDriveUpdater", code: 11, userInfo: [NSLocalizedDescriptionKey: "Downloaded size mismatch (\(actualSize) vs expected \(expectedSize) bytes). Partial file cleared."])
        }

        // Compute SHA-256 streaming
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        let digest = hasher.finalize()
        let actualSha256 = digest.map { String(format: "%02x", $0) }.joined().lowercased()

        let normalizedExpectedSha = expectedSha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedExpectedSha.isEmpty && actualSha256 == normalizedExpectedSha else {
            try? FileManager.default.removeItem(at: fileURL)
            throw NSError(domain: "ZeroDriveUpdater", code: 12, userInfo: [NSLocalizedDescriptionKey: "SHA-256 verification failed. The download may be corrupted or tampered with."])
        }

        // Verify ECDSA P-256 signature over canonical descriptor
        let trimmedSig = signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSig.isEmpty, let sigData = Data(base64Encoded: trimmedSig) else {
            try? FileManager.default.removeItem(at: fileURL)
            throw NSError(domain: "ZeroDriveUpdater", code: 13, userInfo: [NSLocalizedDescriptionKey: "Cryptographic signature verification failed! Update release signature is missing or invalid."])
        }

        let canonicalPayload = "zerodrive-release-v1:\(platform):\(version):\(actualSha256):\(actualSize)"
        guard let payloadData = canonicalPayload.data(using: .utf8) else {
            throw NSError(domain: "ZeroDriveUpdater", code: 14, userInfo: [NSLocalizedDescriptionKey: "Failed to encode canonical release payload."])
        }

        let cleanPEM = publicKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        let publicKey: P256.Signing.PublicKey
        let ecdsaSignature: P256.Signing.ECDSASignature
        do {
            publicKey = try P256.Signing.PublicKey(pemRepresentation: cleanPEM)
            ecdsaSignature = try P256.Signing.ECDSASignature(derRepresentation: sigData)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw NSError(domain: "ZeroDriveUpdater", code: 15, userInfo: [NSLocalizedDescriptionKey: "Cryptographic signature verification failed! The release signature is malformed or invalid."])
        }

        guard publicKey.isValidSignature(ecdsaSignature, for: payloadData) else {
            try? FileManager.default.removeItem(at: fileURL)
            throw NSError(domain: "ZeroDriveUpdater", code: 15, userInfo: [NSLocalizedDescriptionKey: "Cryptographic signature verification failed! Refusing to install unverified update."])
        }
    }

    public nonisolated static func extractAndVerifyMacAppBundle(zipURL: URL, stageDir: URL) throws -> URL {
        // Extract with ditto to preserve resource forks, symlinks, and code signatures
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipURL.path, stageDir.path]
        let errPipe = Pipe()
        ditto.standardError = errPipe
        try ditto.run()
        ditto.waitUntilExit()
        if ditto.terminationStatus != 0 {
            let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "ZeroDriveUpdater", code: 20, userInfo: [NSLocalizedDescriptionKey: "Failed to unpack update archive: \(errText)"])
        }

        let directApp = stageDir.appendingPathComponent("ZeroDrive.app")
        let stagedApp: URL
        if FileManager.default.fileExists(atPath: directApp.path) {
            stagedApp = directApp
        } else {
            let items = (try? FileManager.default.contentsOfDirectory(at: stageDir, includingPropertiesForKeys: nil)) ?? []
            if let found = items.first(where: { $0.pathExtension == "app" }) {
                stagedApp = found
            } else {
                throw NSError(domain: "ZeroDriveUpdater", code: 21, userInfo: [NSLocalizedDescriptionKey: "Update archive did not contain ZeroDrive.app."])
            }
        }

        // Verify CFBundleIdentifier matches co.aisimple.zerodrive
        let plistURL = stagedApp.appendingPathComponent("Contents/Info.plist")
        guard let plistData = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String,
              bundleID == expectedBundleID else {
            throw NSError(domain: "ZeroDriveUpdater", code: 22, userInfo: [NSLocalizedDescriptionKey: "Staged app bundle identifier mismatch."])
        }

        // Strip quarantine xattrs so Gatekeeper never prompts after self-update
        let xattrProc = Process()
        xattrProc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattrProc.arguments = ["-dr", "com.apple.quarantine", stagedApp.path]
        try? xattrProc.run()
        xattrProc.waitUntilExit()

        // Verify macOS code signature deeply & strictly
        let csProc = Process()
        csProc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        csProc.arguments = ["--verify", "--deep", "--strict", stagedApp.path]
        let csErrPipe = Pipe()
        csProc.standardError = csErrPipe
        try csProc.run()
        csProc.waitUntilExit()
        if csProc.terminationStatus != 0 {
            let csErr = String(data: csErrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "ZeroDriveUpdater", code: 23, userInfo: [NSLocalizedDescriptionKey: "macOS code signature verification failed: \(csErr)"])
        }

        // Verify TeamIdentifier matches our Developer ID if Developer ID signed
        let dvProc = Process()
        dvProc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        dvProc.arguments = ["-dv", stagedApp.path]
        let dvPipe = Pipe()
        dvProc.standardError = dvPipe
        try dvProc.run()
        dvProc.waitUntilExit()
        let dvInfo = String(data: dvPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if dvInfo.contains("Authority=") && dvInfo.contains("TeamIdentifier=") && !dvInfo.contains("TeamIdentifier=\(expectedTeamID)") {
            throw NSError(domain: "ZeroDriveUpdater", code: 24, userInfo: [NSLocalizedDescriptionKey: "Unexpected Apple Developer Team ID in update bundle."])
        }

        return stagedApp
    }

    public nonisolated static func resolveInstalledAppBundleURL() -> URL {
        let currentURL = Bundle.main.bundleURL
        if currentURL.pathExtension == "app" && FileManager.default.fileExists(atPath: currentURL.path) {
            return currentURL
        }
        return URL(fileURLWithPath: "/Applications/ZeroDrive.app")
    }

    public nonisolated static func atomicReplaceAppBundle(stagedApp: URL, targetApp: URL) throws {
        let fm = FileManager.default
        let parentDir = targetApp.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let backupApp = parentDir.appendingPathComponent("\(targetApp.lastPathComponent).backup-\(UUID().uuidString.prefix(6))")
        var hadExisting = false

        if fm.fileExists(atPath: targetApp.path) {
            hadExisting = true
            try fm.moveItem(at: targetApp, to: backupApp)
        }

        do {
            try fm.moveItem(at: stagedApp, to: targetApp)
            if hadExisting && fm.fileExists(atPath: backupApp.path) {
                try? fm.removeItem(at: backupApp)
            }
        } catch {
            if hadExisting && fm.fileExists(atPath: backupApp.path) && !fm.fileExists(atPath: targetApp.path) {
                try? fm.moveItem(at: backupApp, to: targetApp)
            }
            throw error
        }
    }

    private func launchDetachedInstallerAndQuit(stagedApp: URL, targetApp: URL, stageDir: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerodrive-apply-update-\(pid).sh")
        let logURL = updatesCacheDir.appendingPathComponent("last-install.log")

        let backupPath = "\(targetApp.path).backup.\(pid)"
        let script = """
        #!/usr/bin/env bash
        set -uo pipefail
        LOG_FILE="\(logURL.path)"
        exec >"$LOG_FILE" 2>&1
        OLD_PID=\(pid)
        STAGED="\(stagedApp.path)"
        TARGET="\(targetApp.path)"
        BACKUP="\(backupPath)"
        STAGE_DIR="\(stageDir.path)"

        for _ in $(seq 1 60); do
          if ! kill -0 "$OLD_PID" 2>/dev/null; then
            break
          fi
          sleep 0.25
        done

        rollback() {
          echo "[Update] Rolling back to previous version..."
          if [ -d "$BACKUP" ]; then
            rm -rf "$TARGET" 2>/dev/null || true
            mv "$BACKUP" "$TARGET" 2>/dev/null || true
          fi
          open "$TARGET" >/dev/null 2>&1 || true
          exit 1
        }

        if [ -d "$TARGET" ]; then
          if ! mv "$TARGET" "$BACKUP"; then
            # Fallback to privileged AppleScript prompt if /Applications requires admin rights
            osascript -e "do shell script \\"mv '$TARGET' '$BACKUP' && mv '$STAGED' '$TARGET' && xattr -dr com.apple.quarantine '$TARGET'\\" with administrator privileges" || rollback
            rm -rf "$BACKUP" "$STAGE_DIR" 2>/dev/null || true
            open "$TARGET"
            exit 0
          fi
        fi

        if ! mv "$STAGED" "$TARGET"; then
          rollback
        fi

        xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
        if ! codesign --verify --deep --strict "$TARGET"; then
          rollback
        fi

        rm -rf "$BACKUP" "$STAGE_DIR" 2>/dev/null || true
        sleep 0.4
        open "$TARGET"
        rm -f "\(scriptURL.path)" 2>/dev/null || true
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptURL.path]
        proc.standardInput = nil
        proc.standardOutput = nil
        proc.standardError = nil
        try proc.run()

        Task { @MainActor in
            await RcloneDaemonSupervisor.shared.unmountCleanly()
            NSApp.terminate(nil)
        }
    }

    // MARK: - Persistence

    private func loadState() -> UpdatePersistentState {
        guard let data = try? Data(contentsOf: stateFileURL),
              let state = try? JSONDecoder().decode(UpdatePersistentState.self, from: data) else {
            return UpdatePersistentState()
        }
        return state
    }

    private func saveState(_ state: UpdatePersistentState) {
        let dir = stateFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(state) {
            try? data.write(to: stateFileURL, options: .atomic)
        }
    }

    // MARK: - Headless CLI Verification Mode (--verify-auto-update)

    public static func runHeadlessUpdateVerificationAndExit() -> Never {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        func argValue(_ flag: String) -> String? {
            guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
            return args[idx + 1]
        }

        let targetPath = argValue("--target-app-path") ?? "/tmp/zerodrive-e2e-macos/ZeroDrive.app"
        let targetURL = URL(fileURLWithPath: targetPath)
        let simulateBadSha = args.contains("--simulate-bad-sha")
        let simulateBadSig = args.contains("--simulate-bad-sig")

        Task { @MainActor in
            var exitCode: Int32 = 1
            let updater = ManageAppUpdates.shared
            // Read current version from target bundle if present
            let targetPlist = targetURL.appendingPathComponent("Contents/Info.plist")
            if let data = try? Data(contentsOf: targetPlist),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let ver = plist["CFBundleShortVersionString"] as? String {
                updater.currentVersion = ver
            }

            print("[VerifyUpdate] Checking updates for ZeroDrive v\(updater.currentVersion) against \(updater.apiBaseURL)...")
            await updater.checkForUpdates(trigger: .manual)

            guard updater.updateAvailable, let latest = updater.latestRelease, var artifact = updater.platformArtifact else {
                print("[VerifyUpdate] FAIL: Expected an available update, got updateAvailable=\(updater.updateAvailable), error=\(updater.errorMessage)")
                Foundation.exit(1)
            }

            print("[VerifyUpdate] Update detected: v\(updater.currentVersion) -> v\(latest.version)")
            print("[VerifyUpdate] Missed releases included in changelog: \(updater.missedReleases.map { $0.version }.joined(separator: ", "))")

            if simulateBadSha {
                artifact = PlatformArtifactInfo(
                    platform: artifact.platform, arch: artifact.arch, filename: artifact.filename,
                    url: artifact.url, dmg_url: artifact.dmg_url, size: artifact.size,
                    sha256: String(repeating: "0", count: 64), signature: artifact.signature,
                    signature_alg: artifact.signature_alg, signed_payload: artifact.signed_payload,
                    team_id: artifact.team_id, notarized: artifact.notarized, minimum_os: artifact.minimum_os
                )
                updater.platformArtifact = artifact
            } else if simulateBadSig {
                artifact = PlatformArtifactInfo(
                    platform: artifact.platform, arch: artifact.arch, filename: artifact.filename,
                    url: artifact.url, dmg_url: artifact.dmg_url, size: artifact.size,
                    sha256: artifact.sha256, signature: Data("invalid_signature_bytes".utf8).base64EncodedString(),
                    signature_alg: artifact.signature_alg, signed_payload: artifact.signed_payload,
                    team_id: artifact.team_id, notarized: artifact.notarized, minimum_os: artifact.minimum_os
                )
                updater.platformArtifact = artifact
            }

            await updater.downloadAndInstallUpdate(targetAppOverride: targetURL, skipRelaunch: true)

            if simulateBadSha {
                if updater.errorMessage.contains("SHA-256 verification failed") {
                    print("[VerifyUpdate] PASS (negative security test rejected tampered update): \(updater.errorMessage)")
                    exitCode = 0
                } else {
                    print("[VerifyUpdate] FAIL: Expected SHA-256 rejection, got: \(updater.errorMessage)")
                    exitCode = 1
                }
                Foundation.exit(exitCode)
            } else if simulateBadSig {
                if updater.errorMessage.contains("Cryptographic signature verification failed") || updater.errorMessage.localizedCaseInsensitiveContains("signature") {
                    print("[VerifyUpdate] PASS (negative security test rejected tampered update): \(updater.errorMessage)")
                    exitCode = 0
                } else {
                    print("[VerifyUpdate] FAIL: Expected ECDSA signature rejection, got: \(updater.errorMessage)")
                    exitCode = 1
                }
                Foundation.exit(exitCode)
            }

            if !updater.errorMessage.isEmpty {
                print("[VerifyUpdate] FAIL: \(updater.errorMessage)")
                Foundation.exit(1)
            }

            // Confirm installed bundle version on disk now matches latest.version
            if let newData = try? Data(contentsOf: targetPlist),
               let newPlist = try? PropertyListSerialization.propertyList(from: newData, format: nil) as? [String: Any],
               let newVer = newPlist["CFBundleShortVersionString"] as? String,
               newVer == latest.version {
                print("[VerifyUpdate] PASS: Atomically upgraded \(targetURL.path) to v\(newVer) and verified Developer ID signature.")
                exitCode = 0
            } else {
                print("[VerifyUpdate] FAIL: Target bundle version did not update to v\(latest.version).")
                exitCode = 1
            }

            Foundation.exit(exitCode)
        }

        while true {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }
}
