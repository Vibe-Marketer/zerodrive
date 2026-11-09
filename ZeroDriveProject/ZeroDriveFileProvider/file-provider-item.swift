import Foundation
import FileProvider
import UniformTypeIdentifiers

public struct RemoteItemRecord: Codable, Sendable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int64
    public let modified: String?
    public let mimeType: String?
    public let etag: String?

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case isDirectory = "is_directory"
        case size
        case modified
        case mimeType = "mime_type"
        case etag
    }
}

public class FileProviderItem: NSObject, NSFileProviderItem {
    public let itemIdentifier: NSFileProviderItemIdentifier
    public let parentItemIdentifier: NSFileProviderItemIdentifier
    public let filename: String
    public let contentType: UTType
    public let documentSize: NSNumber?
    public let contentModificationDate: Date?
    public let itemVersion: NSFileProviderItemVersion
    public let capabilities: NSFileProviderItemCapabilities

    public static var root: FileProviderItem {
        return FileProviderItem(
            identifier: .rootContainer,
            parentIdentifier: .rootContainer,
            filename: "ZeroDrive",
            isDirectory: true,
            size: 0,
            modifiedDate: Date(),
            etag: "root"
        )
    }

    public init(
        identifier: NSFileProviderItemIdentifier,
        parentIdentifier: NSFileProviderItemIdentifier,
        filename: String,
        isDirectory: Bool,
        size: Int64,
        modifiedDate: Date?,
        etag: String?
    ) {
        self.itemIdentifier = identifier
        self.parentItemIdentifier = parentIdentifier
        self.filename = filename

        if isDirectory {
            self.contentType = .folder
            self.documentSize = nil
            self.capabilities = [
                .allowsReading,
                .allowsWriting,
                .allowsRenaming,
                .allowsReparenting,
                .allowsDeleting,
                .allowsAddingSubItems
            ]
        } else {
            let ext = (filename as NSString).pathExtension
            if !ext.isEmpty, let ut = UTType(filenameExtension: ext) {
                self.contentType = ut
            } else {
                self.contentType = .data
            }
            self.documentSize = NSNumber(value: size)
            self.capabilities = [
                .allowsReading,
                .allowsWriting,
                .allowsRenaming,
                .allowsReparenting,
                .allowsDeleting
            ]
        }

        self.contentModificationDate = modifiedDate ?? Date()

        let contentVer = (etag ?? "1").data(using: .utf8) ?? Data()
        let metaVer = "\(size)_\(modifiedDate?.timeIntervalSince1970 ?? 0)".data(using: .utf8) ?? Data()
        self.itemVersion = NSFileProviderItemVersion(contentVersion: contentVer, metadataVersion: metaVer)

        super.init()
    }

    public convenience init(record: RemoteItemRecord) {
        let cleanPath = record.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let identifier = NSFileProviderItemIdentifier(cleanPath)

        let parentIdentifier: NSFileProviderItemIdentifier
        if let lastSlash = cleanPath.lastIndex(of: "/") {
            let parentPath = String(cleanPath[..<lastSlash])
            parentIdentifier = NSFileProviderItemIdentifier(parentPath)
        } else {
            parentIdentifier = .rootContainer
        }

        let parsedDate: Date?
        if let modStr = record.modified {
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            parsedDate = isoFormatter.date(from: modStr) ?? ISO8601DateFormatter().date(from: modStr)
        } else {
            parsedDate = nil
        }

        self.init(
            identifier: identifier,
            parentIdentifier: parentIdentifier,
            filename: record.name,
            isDirectory: record.isDirectory,
            size: record.size,
            modifiedDate: parsedDate,
            etag: record.etag
        )
    }
}
