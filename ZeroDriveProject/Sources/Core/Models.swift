import Foundation

public enum StorageMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case dfyManaged = "dfy"
    case byokOpen = "byok"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .dfyManaged: return "ZeroDrive Managed Vault (1-Click DFY)"
        case .byokOpen: return "Bring Your Own Key (BYOK / Open Mode)"
        }
    }
}

public enum CloudPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case cloudflareR2 = "cloudflare_r2"
    case backblazeB2 = "backblaze_b2"
    case awsS3 = "aws_s3"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .cloudflareR2: return "Cloudflare R2 (Zero Egress)"
        case .backblazeB2: return "Backblaze B2 (High Durability)"
        case .awsS3: return "AWS S3 / S3-Compatible"
        }
    }
}

public enum ExternalCloudProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case googleDrive = "drive"
    case dropbox = "dropbox"
    case oneDrive = "onedrive"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .googleDrive: return "Google Drive"
        case .dropbox: return "Dropbox"
        case .oneDrive: return "OneDrive"
        }
    }

    public var folderName: String {
        switch self {
        case .googleDrive: return "Google Drive"
        case .dropbox: return "Dropbox"
        case .oneDrive: return "OneDrive"
        }
    }

    public var sectionName: String {
        "ext_\(rawValue)"
    }

    public var systemIcon: String {
        switch self {
        case .googleDrive: return "externaldrive.connected.to.line.below"
        case .dropbox: return "shippingbox.fill"
        case .oneDrive: return "cloud.fill"
        }
    }
}

public struct CloudNode: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let relativePath: String
    public let sizeBytes: Int64
    public let isFolder: Bool
    public let sourceCloud: String
    public let updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        relativePath: String,
        sizeBytes: Int64,
        isFolder: Bool,
        sourceCloud: String,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
        self.isFolder = isFolder
        self.sourceCloud = sourceCloud
        self.updatedAt = updatedAt
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

public enum SpoolStatus: String, Codable, Sendable {
    case staging = "staging"
    case uploading = "uploading"
    case pausedOffline = "paused_offline"
    case synced = "synced"
    case purged = "purged"
    case retake = "retake"
}

public struct SpoolItem: Identifiable, Sendable {
    public let id: String
    public var filename: String
    public var relativePath: String
    public var sizeBytes: Int64
    public var status: SpoolStatus
    public var writeBackRemainingSec: Int
    public var uploadProgress: Double
    public var mediaDuration: String?
    public var localCachePath: URL
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        filename: String,
        relativePath: String,
        sizeBytes: Int64,
        status: SpoolStatus,
        writeBackRemainingSec: Int = 15,
        uploadProgress: Double = 0.0,
        mediaDuration: String? = nil,
        localCachePath: URL,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.filename = filename
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
        self.status = status
        self.writeBackRemainingSec = writeBackRemainingSec
        self.uploadProgress = uploadProgress
        self.mediaDuration = mediaDuration
        self.localCachePath = localCachePath
        self.createdAt = createdAt
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

public struct APFSPreFlightResult: Sendable {
    public let canStage: Bool
    public let isWarning: Bool
    public let isCritical: Bool
    public let freeDiskBytes: Int64
    public let shortfallBytes: Int64
    public let warningMessage: String
}

public struct BandwidthSample: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let speedMBps: Double

    public init(timestamp: Date = Date(), speedMBps: Double) {
        self.timestamp = timestamp
        self.speedMBps = speedMBps
    }
}

public struct Telemetry: Sendable {
    public var uploadSpeedMBps: Double = 0.0
    public var downloadSpeedMBps: Double = 0.0
    public var activeUploads: Int = 0
    public var activeQueued: Int = 0
    public var spoolUsedBytes: Int64 = 0
    public var spoolMaxBytes: Int64 = 50 * 1024 * 1024 * 1024
    public var freeAPFSBytes: Int64 = 100 * 1024 * 1024 * 1024
    public var totalSpaceSavedBytes: Int64 = 0
    public var ramIndexCount: Int = 0
    public var isOnline: Bool = true
    public var streamGuardActive: Bool = false
    public var lastRefreshed: Date = Date()

    public init() {}
}
