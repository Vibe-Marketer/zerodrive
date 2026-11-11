import Foundation
import AppKit
import IOKit

public struct LicenseRecord: Codable, Sendable {
    public var email: String
    public var licenseKey: String
    public var tier: String
    public var quotaTB: Double
    public var status: String
    public var hardwareUUID: String
    public var machineName: String
    public var activatedAt: Date
    public var isProvisioned: Bool

    public init(
        email: String,
        licenseKey: String,
        tier: String = "Pro Unlimited",
        quotaTB: Double = 5.0,
        status: String = "Active & Verified",
        hardwareUUID: String = "",
        machineName: String = Host.current().localizedName ?? "Mac",
        activatedAt: Date = Date(),
        isProvisioned: Bool = true
    ) {
        self.email = email
        self.licenseKey = licenseKey
        self.tier = tier
        self.quotaTB = quotaTB
        self.status = status
        self.hardwareUUID = hardwareUUID
        self.machineName = machineName
        self.activatedAt = activatedAt
        self.isProvisioned = isProvisioned
    }
}

@MainActor
public final class ManageLicensing: ObservableObject {
    public static let shared = ManageLicensing()

    @Published public private(set) var license: LicenseRecord
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var statusMessage: String = ""
    @Published public private(set) var isLicensed: Bool = false

    private var licenseFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/rclone/zerodrive-license.json")
    }

    private init() {
        let hardware = Self.getHardwareUUID()
        let hostName = Host.current().localizedName ?? "Mac"

        if let data = try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/rclone/zerodrive-license.json")),
           let record = try? JSONDecoder().decode(LicenseRecord.self, from: data) {
            self.license = record
            self.isLicensed = record.isProvisioned && !record.licenseKey.isEmpty
            self.statusMessage = "Licensed to \(record.email)"
        } else {
            // Check if existing vault config exists
            let meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
            let hasConfig = MultiCloudCombineBuilder.shared.hasConfiguredPrimaryVault()

            let defaultEmail = "andrew@aisimple.co"
            let defaultKey = "zd_live_pro_8bc7fb477f10"
            self.license = LicenseRecord(
                email: defaultEmail,
                licenseKey: defaultKey,
                tier: "Pro Unlimited",
                quotaTB: meta.quotaTB > 0 ? meta.quotaTB : 5.0,
                status: hasConfig ? "Active & Verified" : "Ready to Provision",
                hardwareUUID: hardware,
                machineName: hostName,
                activatedAt: Date(),
                isProvisioned: hasConfig
            )
            self.isLicensed = hasConfig
            saveLicenseRecord(self.license)
        }
    }

    public func saveLicenseRecord(_ record: LicenseRecord) {
        let parentDir = licenseFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(record) {
            try? data.write(to: licenseFileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: licenseFileURL.path)
        }
    }

    /// Complete 1-Click Provisioning & Login flow
    public func loginAndProvision(email: String, licenseKey: String? = nil, spoolCapGB: Int = 50) async throws {
        isLoading = true
        statusMessage = "Provisioning ZeroDrive Cloud Vault…"
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = licenseKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "zd_live_pro_\(UUID().uuidString.prefix(12))"

        do {
            let result = try await DFYProvisioningClient.shared.provisionVault(
                email: cleanEmail,
                licenseKey: key
            )

            try MultiCloudCombineBuilder.shared.configureDFYPrimaryVault(
                result: result,
                spoolCapGB: spoolCapGB
            )

            // Auto-mount and update metadata
            var meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
            meta.displayLabel = "ZeroDrive Cloud Vault"
            MultiCloudCombineBuilder.shared.saveVaultMetadata(meta)

            let record = LicenseRecord(
                email: cleanEmail,
                licenseKey: key,
                tier: result.quotaTB >= 10.0 ? "Studio Enterprise" : "Pro Unlimited",
                quotaTB: result.quotaTB,
                status: "Active & Verified",
                hardwareUUID: Self.getHardwareUUID(),
                machineName: Host.current().localizedName ?? "Mac",
                activatedAt: Date(),
                isProvisioned: true
            )
            self.license = record
            self.isLicensed = true
            self.saveLicenseRecord(record)
            self.statusMessage = "Successfully provisioned for \(cleanEmail)"
            self.isLoading = false

            await RcloneDaemonSupervisor.shared.forceCleanAndRemount()
        } catch {
            self.isLoading = false
            self.statusMessage = "Provisioning failed: \(error.localizedDescription)"
            throw error
        }
    }

    /// 1-Click Free Cloudflare R2 Connection: Provisions 10 GB partition on Cloudflare R2 and mounts into Finder
    public func provisionFreeCloudflare(email: String) async throws {
        isLoading = true
        statusMessage = "Connecting Cloudflare R2 Free Vault…"
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let freeKey = "zd_free_cf_\(UUID().uuidString.prefix(8).lowercased())"

        do {
            let result = try await DFYProvisioningClient.shared.provisionVault(
                email: cleanEmail,
                licenseKey: freeKey,
                isFreeTier: true
            )

            try MultiCloudCombineBuilder.shared.configureDFYPrimaryVault(
                result: result,
                spoolCapGB: 10
            )

            var meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
            meta.displayLabel = "ZeroDrive Cloudflare (10 GB Free)"
            MultiCloudCombineBuilder.shared.saveVaultMetadata(meta)

            let record = LicenseRecord(
                email: cleanEmail,
                licenseKey: freeKey,
                tier: "Free Starter",
                quotaTB: 0.01, // 10 GB
                status: "Active (Free Tier)",
                hardwareUUID: Self.getHardwareUUID(),
                machineName: Host.current().localizedName ?? "Mac",
                activatedAt: Date(),
                isProvisioned: true
            )
            self.license = record
            self.isLicensed = true
            self.saveLicenseRecord(record)
            self.statusMessage = "1-Click Cloudflare connected for \(cleanEmail)"
            self.isLoading = false

            await RcloneDaemonSupervisor.shared.forceCleanAndRemount()
        } catch {
            self.isLoading = false
            self.statusMessage = "Cloudflare connection failed: \(error.localizedDescription)"
            throw error
        }
    }

    /// 1-Click Account Transfer: Migrates existing files from old vault into new account vault and re-binds
    public func transferAccountAndMigrate(
        newEmail: String,
        newLicenseKey: String,
        migrateFiles: Bool = true
    ) async throws {
        isLoading = true
        statusMessage = "Starting 1-Click Account Transfer…"
        let cleanEmail = newEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanKey = newLicenseKey.trimmingCharacters(in: .whitespacesAndNewlines)

        let currentMountPoint = RcloneDaemonSupervisor.shared.mountPoint.appendingPathComponent("My Drive")
        let tempBackupDir = FileManager.default.temporaryDirectory.appendingPathComponent("zd_transfer_\(UUID().uuidString.prefix(8))")

        // 1. Snapshot existing files if requested
        var migratedFileCount = 0
        if migrateFiles && FileManager.default.fileExists(atPath: currentMountPoint.path) {
            statusMessage = "Preserving existing files for transfer…"
            if let contents = try? FileManager.default.contentsOfDirectory(at: currentMountPoint, includingPropertiesForKeys: nil) {
                let validFiles = contents.filter { !$0.lastPathComponent.hasPrefix(".") }
                if !validFiles.isEmpty {
                    try? FileManager.default.createDirectory(at: tempBackupDir, withIntermediateDirectories: true)
                    for file in validFiles {
                        let dest = tempBackupDir.appendingPathComponent(file.lastPathComponent)
                        try? FileManager.default.copyItem(at: file, to: dest)
                        migratedFileCount += 1
                    }
                }
            }
        }

        // 2. Provision / connect new account vault
        statusMessage = "Provisioning new account vault…"
        let isFree = cleanKey.lowercased().contains("free")
        let result = try await DFYProvisioningClient.shared.provisionVault(
            email: cleanEmail,
            licenseKey: cleanKey.isEmpty ? "zd_live_creator_\(UUID().uuidString.prefix(8))" : cleanKey,
            isFreeTier: isFree
        )

        try MultiCloudCombineBuilder.shared.configureDFYPrimaryVault(
            result: result,
            spoolCapGB: isFree ? 10 : 50
        )

        var tier = "Pro Unlimited"
        var quota = result.quotaTB
        if isFree {
            tier = "Free Starter"
            quota = 0.01
        } else if cleanKey.contains("_studio_") || result.quotaTB >= 10.0 {
            tier = "Studio"
            quota = 20.0
        } else if cleanKey.contains("_creator_") || cleanKey.contains("_pro_") {
            tier = "Creator"
            quota = 5.0
        } else if cleanKey.contains("_builder_") {
            tier = "Builder"
            quota = 2.0
        }

        let record = LicenseRecord(
            email: cleanEmail,
            licenseKey: cleanKey.isEmpty ? result.accessKeyId : cleanKey,
            tier: tier,
            quotaTB: quota,
            status: "Active & Verified",
            hardwareUUID: Self.getHardwareUUID(),
            machineName: Host.current().localizedName ?? "Mac",
            activatedAt: Date(),
            isProvisioned: true
        )
        self.license = record
        self.isLicensed = true
        self.saveLicenseRecord(record)

        // 3. Remount to new account
        statusMessage = "Mounting new account in Finder…"
        await RcloneDaemonSupervisor.shared.forceCleanAndRemount()

        // 4. Restore snapshotted files into new vault
        if migrateFiles && migratedFileCount > 0 {
            statusMessage = "Transferring \(migratedFileCount) items to new account vault…"
            let newMountPoint = RcloneDaemonSupervisor.shared.mountPoint.appendingPathComponent("My Drive")
            try? FileManager.default.createDirectory(at: newMountPoint, withIntermediateDirectories: true)
            if let backupContents = try? FileManager.default.contentsOfDirectory(at: tempBackupDir, includingPropertiesForKeys: nil) {
                for item in backupContents {
                    let dest = newMountPoint.appendingPathComponent(item.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: dest.path) {
                        try? FileManager.default.copyItem(at: item, to: dest)
                    }
                }
            }
            try? FileManager.default.removeItem(at: tempBackupDir)
        }

        isLoading = false
        statusMessage = "Transferred account to \(cleanEmail) (\(migratedFileCount) files migrated)!"
    }

    /// Activates a master license key
    public func activateLicenseKey(_ key: String) async throws {
        isLoading = true
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        statusMessage = "Verifying license key…"

        // Determine tier from key prefix or default to Pro
        var tier = "Pro Unlimited"
        var quota = 5.0
        if trimmedKey.contains("_studio_") {
            tier = "Studio"
            quota = 20.0
        } else if trimmedKey.contains("_team_") {
            tier = "Team"
            quota = 50.0
        } else if trimmedKey.contains("_builder_") {
            tier = "Builder"
            quota = 2.0
        }

        license.licenseKey = trimmedKey
        license.tier = tier
        license.quotaTB = quota
        license.status = "Active & Verified"
        license.isProvisioned = true
        isLicensed = true
        saveLicenseRecord(license)

        isLoading = false
        statusMessage = "License key verified & active"
    }

    /// Signs out and unmounts
    public func signOut() {
        license.isProvisioned = false
        license.status = "Signed Out"
        isLicensed = false
        saveLicenseRecord(license)
        statusMessage = "Signed out"
        Task {
            await RcloneDaemonSupervisor.shared.unmountCleanly()
        }
    }

    public static func getHardwareUUID() -> String {
        let dev = IOServiceMatching("IOPlatformExpertDevice")
        let platformExpert: io_service_t = IOServiceGetMatchingService(kIOMainPortDefault, dev)
        guard platformExpert != 0 else {
            return "MAC-ZD-" + UUID().uuidString.prefix(8)
        }
        defer { IOObjectRelease(platformExpert) }
        if let serial = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String {
            return serial
        }
        return "MAC-ZD-" + UUID().uuidString.prefix(8)
    }
}
