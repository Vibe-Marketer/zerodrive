import Foundation

public final class MultiCloudCombineBuilder: @unchecked Sendable {
    public static let shared = MultiCloudCombineBuilder()

    public let configPath: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/rclone/rclone.conf")
    }()

    private let metadataPath: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/rclone/zerodrive-vault.json")
    }()

    public struct PrimaryVaultMetadata: Codable, Sendable {
        public var mode: StorageMode
        public var preset: CloudPreset
        public var bucketAndPrefix: String
        public var displayLabel: String
        public var quotaTB: Double
        public var spoolCapGB: Int
        public var minFreeSpaceGB: Int
        public var includeConfigDotFiles: Bool
        public var uploadDevConfigs: Bool     // .git, .github, .claude, etc.
        public var uploadAppWorkspaces: Bool  // .obsidian, .vscode, .cursor, etc.
        public var uploadSecretEnvFiles: Bool // .env, .env.*, credentials, etc.

        public init(
            mode: StorageMode,
            preset: CloudPreset,
            bucketAndPrefix: String,
            displayLabel: String,
            quotaTB: Double,
            spoolCapGB: Int,
            minFreeSpaceGB: Int = 15,
            includeConfigDotFiles: Bool = true,
            uploadDevConfigs: Bool = true,
            uploadAppWorkspaces: Bool = true,
            uploadSecretEnvFiles: Bool = false
        ) {
            self.mode = mode
            self.preset = preset
            self.bucketAndPrefix = bucketAndPrefix
            self.displayLabel = displayLabel
            self.quotaTB = quotaTB
            self.spoolCapGB = spoolCapGB
            self.minFreeSpaceGB = minFreeSpaceGB
            self.includeConfigDotFiles = includeConfigDotFiles
            self.uploadDevConfigs = uploadDevConfigs
            self.uploadAppWorkspaces = uploadAppWorkspaces
            self.uploadSecretEnvFiles = uploadSecretEnvFiles
        }
    }

    public func hasConfiguredPrimaryVault() -> Bool {
        let sections = parseConfigSections()
        return sections["primary_vault"] != nil && sections["ZeroDriveUnified"] != nil
    }

    public func loadVaultMetadata() -> PrimaryVaultMetadata {
        let sections = parseConfigSections()
        let accessKey = sections["primary_vault"]?
            .first(where: { $0.hasPrefix("access_key_id") })?
            .components(separatedBy: "=")
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "usr_andrew_8bc7fb477f"
        let defaultBucketPath = accessKey.hasPrefix("usr_")
            ? "zerodrive-vault-prod/\(accessKey)"
            : "zerodrive-vault-prod/usr_andrew_8bc7fb477f"

        if let data = try? Data(contentsOf: metadataPath),
           var meta = try? JSONDecoder().decode(PrimaryVaultMetadata.self, from: data) {
            if meta.bucketAndPrefix == "zerodrive-vault-prod" || meta.bucketAndPrefix.isEmpty {
                meta.bucketAndPrefix = defaultBucketPath
                saveVaultMetadata(meta)
            }
            return meta
        }
        return PrimaryVaultMetadata(
            mode: .dfyManaged,
            preset: .cloudflareR2,
            bucketAndPrefix: defaultBucketPath,
            displayLabel: "ZeroDrive Cloud Vault",
            quotaTB: 1.0,
            spoolCapGB: 50,
            minFreeSpaceGB: 15,
            includeConfigDotFiles: true,
            uploadDevConfigs: true,
            uploadAppWorkspaces: true,
            uploadSecretEnvFiles: false
        )
    }

    public func saveVaultMetadata(_ meta: PrimaryVaultMetadata) {
        let parentDir = metadataPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metadataPath, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataPath.path)
        }
    }

    /// Configures [primary_vault] for 1-Click DFY Managed Vault and rebuilds [ZeroDriveUnified]
    public func configureDFYPrimaryVault(result: DFYProvisionResult, spoolCapGB: Int = 50) throws {
        var sections = parseConfigSections()

        sections["primary_vault"] = [
            "type = s3",
            "provider = Cloudflare",
            "access_key_id = \(result.accessKeyId)",
            "secret_access_key = \(result.secretAccessKey)",
            "endpoint = \(result.endpoint)",
            "acl = private",
            "force_path_style = true",
            "no_check_bucket = true",
            "use_server_modtime = true",
            "disable_http2 = true",
            "upload_cutoff = 32M",
            "chunk_size = 8M",
            "upload_concurrency = 2"
        ]

        let bucketPath = result.userPrefix.isEmpty
            ? result.bucket
            : "\(result.bucket)/\(result.userPrefix)"

        let meta = PrimaryVaultMetadata(
            mode: .dfyManaged,
            preset: .cloudflareR2,
            bucketAndPrefix: bucketPath,
            displayLabel: "ZeroDrive Cloud Vault",
            quotaTB: result.quotaTB,
            spoolCapGB: spoolCapGB
        )
        saveVaultMetadata(meta)

        try writeSectionsAndRebuildCombine(&sections, primaryBucketPath: bucketPath)
    }

    /// Configures [primary_vault] for BYOK Mode (Cloudflare R2, Backblaze B2, AWS S3)
    public func configureBYOKPrimaryVault(
        preset: CloudPreset,
        bucket: String,
        accessKey: String,
        secretKey: String,
        endpoint: String,
        region: String = "auto",
        spoolCapGB: Int = 50
    ) throws {
        var sections = parseConfigSections()

        switch preset {
        case .cloudflareR2:
            sections["primary_vault"] = [
                "type = s3",
                "provider = Cloudflare",
                "access_key_id = \(accessKey)",
                "secret_access_key = \(secretKey)",
                "endpoint = \(endpoint.isEmpty ? "https://auto.r2.cloudflarestorage.com" : endpoint)",
                "region = auto",
                "no_check_bucket = true",
                "use_server_modtime = true",
                "disable_http2 = true",
                "upload_cutoff = 32M",
                "chunk_size = 8M",
                "upload_concurrency = 2"
            ]
        case .backblazeB2:
            sections["primary_vault"] = [
                "type = b2",
                "account = \(accessKey)",
                "key = \(secretKey)",
                "hard_delete = false",
                "upload_cutoff = 64M",
                "chunk_size = 64M"
            ]
        case .awsS3:
            var lines = [
                "type = s3",
                "provider = \(endpoint.isEmpty ? "AWS" : "Other")",
                "access_key_id = \(accessKey)",
                "secret_access_key = \(secretKey)",
                "region = \(region.isEmpty ? "us-east-1" : region)",
                "use_server_modtime = true",
                "disable_http2 = true",
                "upload_cutoff = 32M",
                "chunk_size = 8M",
                "upload_concurrency = 2"
            ]
            if !endpoint.isEmpty {
                lines.append("endpoint = \(endpoint)")
            }
            sections["primary_vault"] = lines
        }

        let cleanBucket = bucket.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let meta = PrimaryVaultMetadata(
            mode: .byokOpen,
            preset: preset,
            bucketAndPrefix: cleanBucket,
            displayLabel: "\(preset.displayName) (\(cleanBucket))",
            quotaTB: 10.0,
            spoolCapGB: spoolCapGB
        )
        saveVaultMetadata(meta)

        try writeSectionsAndRebuildCombine(&sections, primaryBucketPath: cleanBucket)
    }

    /// Validates [primary_vault] credentials using `rclone lsd` with a 10-second timeout
    public func validatePrimaryVault(rcloneURL: URL, bucket: String) async -> (Bool, String) {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = rcloneURL
                proc.arguments = [
                    "lsd",
                    "primary_vault:\(bucket)",
                    "--config=\(self.configPath.path)",
                    "--contimeout=8s",
                    "--timeout=10s",
                    "--retries=1"
                ]
                let errPipe = Pipe()
                proc.standardError = errPipe
                proc.standardOutput = Pipe()

                do {
                    try proc.run()
                } catch {
                    continuation.resume(returning: (false, error.localizedDescription))
                    return
                }

                let deadline = Date().addingTimeInterval(10.0)
                while proc.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if proc.isRunning {
                    proc.terminate()
                    continuation.resume(returning: (false, "Connection timed out after 10 seconds."))
                    return
                }

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: (true, "Verified successfully"))
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Invalid credentials"
                    continuation.resume(returning: (false, errStr))
                }
            }
        }
    }

    /// Launches browser OAuth flow via `rclone config create` for Google Drive, Dropbox, or OneDrive
    public func connectExternalCloudOAuth(
        provider: ExternalCloudProvider,
        rcloneURL: URL,
        customClientId: String? = nil,
        customClientSecret: String? = nil
    ) async -> (Bool, String) {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = rcloneURL

                var args: [String] = [
                    "config",
                    "create",
                    provider.sectionName,
                    provider.rawValue,
                    "--config=\(self.configPath.path)"
                ]

                switch provider {
                case .googleDrive:
                    args.append(contentsOf: ["scope", "drive", "chunk_size", "32M", "pacer_min_sleep", "10ms"])
                    if let cid = customClientId, !cid.isEmpty {
                        args.append(contentsOf: ["client_id", cid])
                    }
                    if let csec = customClientSecret, !csec.isEmpty {
                        args.append(contentsOf: ["client_secret", csec])
                    }
                case .dropbox:
                    args.append(contentsOf: ["chunk_size", "48M"])
                case .oneDrive:
                    args.append(contentsOf: ["chunk_size", "32M"])
                }

                proc.arguments = args
                let errPipe = Pipe()
                proc.standardError = errPipe
                proc.standardOutput = Pipe()

                do {
                    try proc.run()
                    proc.waitUntilExit()
                } catch {
                    continuation.resume(returning: (false, error.localizedDescription))
                    return
                }

                if proc.terminationStatus == 0 {
                    var sections = self.parseConfigSections()
                    let meta = self.loadVaultMetadata()
                    try? self.writeSectionsAndRebuildCombine(&sections, primaryBucketPath: meta.bucketAndPrefix)
                    continuation.resume(returning: (true, "Connected \(provider.displayName)"))
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errStr = String(data: errData, encoding: .utf8) ?? "OAuth flow cancelled or failed."
                    continuation.resume(returning: (false, errStr))
                }
            }
        }
    }

    public func getAccountEmail(for provider: ExternalCloudProvider) -> String? {
        let accountsFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/rclone/cloud-accounts.json")
        if let data = try? Data(contentsOf: accountsFile),
           let map = try? JSONDecoder().decode([String: String].self, from: data),
           let email = map[provider.rawValue] {
            return email
        }
        return nil
    }

    public func saveAccountEmail(_ email: String, for provider: ExternalCloudProvider) {
        let accountsFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/rclone/cloud-accounts.json")
        var map: [String: String] = [:]
        if let data = try? Data(contentsOf: accountsFile),
           let existing = try? JSONDecoder().decode([String: String].self, from: data) {
            map = existing
        }
        map[provider.rawValue] = email
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: accountsFile, options: .atomic)
        }
    }

    public func disconnectExternalCloud(_ provider: ExternalCloudProvider) throws {
        var sections = parseConfigSections()
        sections.removeValue(forKey: provider.sectionName)
        // Also remove any alias remotes of the same type so it stays disconnected
        let typeStr = "type=\(provider.rawValue)"
        let matchingKeys = sections.filter { sec in
            sec.key != "primary_vault" && sec.key != "ZeroDriveUnified" &&
            sec.value.contains(where: { $0.replacingOccurrences(of: " ", with: "") == typeStr })
        }.map(\.key)

        for key in matchingKeys {
            sections.removeValue(forKey: key)
        }

        let meta = loadVaultMetadata()
        try writeSectionsAndRebuildCombine(&sections, primaryBucketPath: meta.bucketAndPrefix, allowAdoption: false)
    }

    private func hasValidToken(_ lines: [String]) -> Bool {
        return lines.contains(where: { $0.hasPrefix("token =") && $0.count > 12 })
    }

    private func adoptExistingCloudTokens(_ sections: inout [String: [String]]) {
        for provider in ExternalCloudProvider.allCases {
            if let existing = sections[provider.sectionName], hasValidToken(existing) {
                continue
            }
            // Look for any existing rclone section of the same type that has a valid OAuth token
            for (secName, lines) in sections where secName != provider.sectionName && secName != "primary_vault" && secName != "ZeroDriveUnified" {
                let isMatchingType = lines.contains(where: { $0.replacingOccurrences(of: " ", with: "") == "type=\(provider.rawValue)" })
                if isMatchingType && hasValidToken(lines) {
                    sections[provider.sectionName] = lines
                    break
                }
            }
        }
    }

    public func ensureUnifiedUnionConfig() {
        var sections = parseConfigSections()
        guard var primaryLines = sections["primary_vault"] else { return }
        let isS3 = primaryLines.contains { $0.replacingOccurrences(of: " ", with: "").lowercased() == "type=s3" }
        if isS3 {
            let ensureKV: (String, String) -> Void = { key, value in
                if let idx = primaryLines.firstIndex(where: {
                    $0.components(separatedBy: "=").first?.trimmingCharacters(in: .whitespaces) == key
                }) {
                    primaryLines[idx] = "\(key) = \(value)"
                } else {
                    primaryLines.append("\(key) = \(value)")
                }
            }
            ensureKV("use_server_modtime", "true")
            ensureKV("disable_http2", "true")
            sections["primary_vault"] = primaryLines
        }
        let meta = loadVaultMetadata()
        try? writeSectionsAndRebuildCombine(&sections, primaryBucketPath: meta.bucketAndPrefix, allowAdoption: false)
    }

    public func connectedExternalClouds() -> Set<ExternalCloudProvider> {
        let sections = parseConfigSections()
        var result = Set<ExternalCloudProvider>()
        for provider in ExternalCloudProvider.allCases {
            if let lines = sections[provider.sectionName], hasValidToken(lines) {
                result.insert(provider)
            }
        }
        return result
    }

    public func rebuildUnifiedRemote(
        primaryBucket: String,
        connectedClouds: [(name: String, remote: String)]
    ) throws {
        var sections = parseConfigSections()
        for provider in ExternalCloudProvider.allCases {
            sections.removeValue(forKey: provider.sectionName)
        }
        let cleanBucket = primaryBucket.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        var upstreams = ["\"My Drive=primary_vault:\(cleanBucket)\""]
        let drives = ManageDrives.loadSavedDrives()
        for d in drives where !d.isDefault {
            let secondaryPath = "\(cleanBucket)/drives/\(d.id)"
            upstreams.append("\"\(d.name)=primary_vault:\(secondaryPath)\"")
        }
        sections["ZeroDriveUnified"] = [
            "type = combine",
            "upstreams = \(upstreams.joined(separator: " "))"
        ]
        try writeConfigSections(sections)
    }

    /// Rebuilds the ZeroDriveUnified combine remote including all secondary/custom drives
    public func rebuildWithDrives(_ drives: [DriveItem]) throws {
        var sections = parseConfigSections()
        let meta = loadVaultMetadata()
        let cleanBucket = meta.bucketAndPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))

        var upstreams = ["\"My Drive=primary_vault:\(cleanBucket)\""]
        for d in drives where !d.isDefault {
            let secondaryPath = "\(cleanBucket)/drives/\(d.id)"
            upstreams.append("\"\(d.name)=primary_vault:\(secondaryPath)\"")
        }

        sections["ZeroDriveUnified"] = [
            "type = combine",
            "upstreams = \(upstreams.joined(separator: " "))"
        ]
        try writeConfigSections(sections)
    }

    // MARK: - Internal INI Parser & Writer (Preserves Existing Remotes + 0600 Permissions)

    private func writeSectionsAndRebuildCombine(
        _ sections: inout [String: [String]],
        primaryBucketPath: String,
        allowAdoption: Bool = false
    ) throws {
        for provider in ExternalCloudProvider.allCases {
            sections.removeValue(forKey: provider.sectionName)
        }

        let cleanBucket = primaryBucketPath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        var upstreams = ["\"My Drive=primary_vault:\(cleanBucket)\""]
        let drives = ManageDrives.loadSavedDrives()
        for d in drives where !d.isDefault {
            let secondaryPath = "\(cleanBucket)/drives/\(d.id)"
            upstreams.append("\"\(d.name)=primary_vault:\(secondaryPath)\"")
        }

        sections["ZeroDriveUnified"] = [
            "type = combine",
            "upstreams = \(upstreams.joined(separator: " "))"
        ]

        try writeConfigSections(sections)
    }

    private func parseConfigSections() -> [String: [String]] {
        guard let content = try? String(contentsOf: configPath, encoding: .utf8) else {
            return [:]
        }
        var sections: [String: [String]] = [:]
        var currentSection: String?

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") {
                continue
            }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                currentSection = name
                if sections[name] == nil {
                    sections[name] = []
                }
            } else if let sec = currentSection {
                sections[sec, default: []].append(line)
            }
        }
        return sections
    }

    private func writeConfigSections(_ sections: [String: [String]]) throws {
        let parentDir = configPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        var output = """
        # ==============================================================================
        # ZeroDrive Multi-Cloud Unification Engine
        # Auto-generated by ZeroDrive Supervisor (0600 POSIX Permissions)
        # ==============================================================================

        """

        let orderedKeys = ["primary_vault"] +
            ExternalCloudProvider.allCases.map(\.sectionName) +
            sections.keys.filter { $0 != "primary_vault" && $0 != "ZeroDriveUnified" && !ExternalCloudProvider.allCases.map(\.sectionName).contains($0) }.sorted() +
            ["ZeroDriveUnified"]

        var written = Set<String>()
        for key in orderedKeys {
            guard !written.contains(key), let lines = sections[key] else { continue }
            written.insert(key)
            output += "[\(key)]\n"
            for line in lines {
                output += "\(line)\n"
            }
            output += "\n"
        }

        try output.write(to: configPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath.path)
    }
}
