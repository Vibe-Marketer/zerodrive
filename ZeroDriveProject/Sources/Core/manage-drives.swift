import Foundation
import AppKit

public struct DriveItem: Codable, Identifiable, Sendable {
    public var id: String          // e.g. "work-drive"
    public var name: String        // "Work Drive"
    public var quotaGB: Double     // e.g. 100.0
    public var isDefault: Bool     // true for primary ("My Drive")
    public var status: String      // "active"
    public var createdAt: Date
    public var provisioningMode: String // "partition" or "dedicated"
    public var targetLocation: String   // "all_fleet", "this_mac", "naegele-pc", "mac_minis", "team_mcp"
    public var priceLabel: String       // "Free (Included)" or "$9/mo"

    public init(
        id: String,
        name: String,
        quotaGB: Double = 100.0,
        isDefault: Bool = false,
        status: String = "active",
        createdAt: Date = Date(),
        provisioningMode: String = "partition",
        targetLocation: String = "all_fleet",
        priceLabel: String = "Free (Included)"
    ) {
        self.id = id
        self.name = name
        self.quotaGB = quotaGB
        self.isDefault = isDefault
        self.status = status
        self.createdAt = createdAt
        self.provisioningMode = provisioningMode
        self.targetLocation = targetLocation
        self.priceLabel = priceLabel
    }
}

@MainActor
public final class ManageDrives: ObservableObject {
    public static let shared = ManageDrives()

    @Published public private(set) var drives: [DriveItem] = []
    @Published public var isWorking: Bool = false
    @Published public var statusMessage: String = ""

    nonisolated public static var drivesFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/rclone/zerodrive-drives.json")
    }

    private init() {
        self.drives = Self.loadSavedDrives()
    }

    nonisolated public static func loadSavedDrives() -> [DriveItem] {
        let file = drivesFileURL
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([DriveItem].self, from: data),
           !saved.isEmpty {
            return saved
        }
        return [
            DriveItem(id: "primary", name: "My Drive", quotaGB: 5000.0, isDefault: true)
        ]
    }

    public func saveDrives() {
        let parent = Self.drivesFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(drives) {
            try? data.write(to: Self.drivesFileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.drivesFileURL.path)

            let sharedCandidate = RcloneDaemonSupervisor.shared.mountPoint.appendingPathComponent("My Drive/_SYSTEM/MACHINES/drives.json")
            if FileManager.default.fileExists(atPath: sharedCandidate.deletingLastPathComponent().path) {
                try? data.write(to: sharedCandidate, options: .atomic)
            }
        }
    }

    /// Verifies if the current license tier allows adding another drive
    public func canAddDrive() -> (allowed: Bool, reason: String) {
        let tier = ManageLicensing.shared.license.tier.lowercased()

        if tier.contains("free") || tier.contains("starter") {
            return (false, "The Free Starter tier includes 1 Primary Drive. Upgrade to Creator or Studio to provision multiple independent drives.")
        }

        if tier.contains("builder") {
            return (false, "The Builder tier includes 1 Vault Container. Upgrade to Creator (2 Vaults) or Studio (Unlimited Vaults) for Multi-Drive.")
        }

        if tier.contains("creator") && drives.count >= 2 {
            return (false, "Creator tier includes up to 2 isolated drives. Upgrade to Studio for unlimited independent drives.")
        }

        return (true, "")
    }

    /// Creates and provisions a new isolated drive
    public func addDrive(
        name: String,
        quotaGB: Double = 100.0,
        provisioningMode: String = "partition",
        targetLocation: String = "all_fleet",
        priceLabel: String = "Free (Included)"
    ) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "ZeroDrive", code: 400, userInfo: [NSLocalizedDescriptionKey: "Drive name cannot be empty."])
        }

        let slug = trimmed
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        let driveId = slug.isEmpty ? "drive-\(UUID().uuidString.prefix(6))" : slug

        if drives.contains(where: { $0.id == driveId || $0.name.lowercased() == trimmed.lowercased() }) {
            throw NSError(domain: "ZeroDrive", code: 409, userInfo: [NSLocalizedDescriptionKey: "A drive named '\(trimmed)' already exists."])
        }

        isWorking = true
        statusMessage = "Provisioning '\(trimmed)' (\(provisioningMode == "partition" ? "Free Partition" : "Dedicated Drive"))…"

        let newItem = DriveItem(
            id: driveId,
            name: trimmed,
            quotaGB: quotaGB,
            isDefault: false,
            provisioningMode: provisioningMode,
            targetLocation: targetLocation,
            priceLabel: priceLabel
        )

        drives.append(newItem)
        saveDrives()

        // 1. Register FileProvider domain for this secondary drive
        try? await ManageFileProvider.shared.addDriveDomain(name: trimmed, identifier: driveId)

        // 2. Rebuild ZeroDriveUnified combine remote with the new drive upstream
        try? MultiCloudCombineBuilder.shared.rebuildWithDrives(drives)

        // 3. Remount so Finder instantly reveals the new drive folder
        await RcloneDaemonSupervisor.shared.forceCleanAndRemount()

        isWorking = false
        statusMessage = "Drive '\(trimmed)' mounted successfully!"
    }

    /// Removes a secondary drive
    public func removeDrive(id: String) async throws {
        guard let index = drives.firstIndex(where: { $0.id == id }) else { return }
        let drive = drives[index]
        guard !drive.isDefault else {
            throw NSError(domain: "ZeroDrive", code: 403, userInfo: [NSLocalizedDescriptionKey: "Cannot remove the Primary Drive."])
        }

        isWorking = true
        statusMessage = "Removing drive '\(drive.name)'…"

        drives.remove(at: index)
        saveDrives()

        // Remove FileProvider domain
        try? await ManageFileProvider.shared.removeDriveDomain(identifier: drive.id)

        // Rebuild combine remote
        try? MultiCloudCombineBuilder.shared.rebuildWithDrives(drives)

        // Remount
        await RcloneDaemonSupervisor.shared.forceCleanAndRemount()

        isWorking = false
        statusMessage = "Drive removed."
    }
}
