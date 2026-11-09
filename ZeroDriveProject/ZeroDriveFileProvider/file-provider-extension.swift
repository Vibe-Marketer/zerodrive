import Foundation
import FileProvider
import UniformTypeIdentifiers

@objc(Extension)
public class Extension: NSObject, NSFileProviderReplicatedExtension {
    public let domain: NSFileProviderDomain
    private let apiClient = ZeroDriveAPIClient.shared

    public required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }

    public func invalidate() {}

    public func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        NSLog("[ZeroDriveFP] item(for: %@)", identifier.rawValue)

        if identifier == .rootContainer {
            completionHandler(FileProviderItem.root, nil)
            progress.completedUnitCount = 1
            return progress
        }

        if identifier == .trashContainer || identifier == .workingSet {
            completionHandler(nil, NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError))
            progress.completedUnitCount = 1
            return progress
        }

        Task {
            do {
                let record = try await self.apiClient.fetchItem(path: identifier.rawValue)
                let item = FileProviderItem(record: record)
                progress.completedUnitCount = 1
                completionHandler(item, nil)
            } catch {
                NSLog("[ZeroDriveFP] item(for: %@) error: %@", identifier.rawValue, error.localizedDescription)
                progress.completedUnitCount = 1
                completionHandler(nil, error)
            }
        }

        return progress
    }

    public func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        Task {
            do {
                let tempDir = FileManager.default.temporaryDirectory
                let tempURL = tempDir.appendingPathComponent(UUID().uuidString + "_" + (itemIdentifier.rawValue as NSString).lastPathComponent)

                try await self.apiClient.downloadFile(path: itemIdentifier.rawValue, to: tempURL)
                let record = try await self.apiClient.fetchItem(path: itemIdentifier.rawValue)
                let item = FileProviderItem(record: record)

                progress.completedUnitCount = 100
                completionHandler(tempURL, item, nil)
            } catch {
                progress.completedUnitCount = 100
                completionHandler(nil, nil, error)
            }
        }

        return progress
    }

    public func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        Task {
            do {
                let parentPath = itemTemplate.parentItemIdentifier == .rootContainer ? "" : itemTemplate.parentItemIdentifier.rawValue
                let fullPath = parentPath.isEmpty ? itemTemplate.filename : "\(parentPath)/\(itemTemplate.filename)"

                let record: RemoteItemRecord
                if let contentsURL = url {
                    record = try await self.apiClient.uploadFile(path: fullPath, from: contentsURL)
                } else {
                    record = RemoteItemRecord(
                        name: itemTemplate.filename,
                        path: fullPath,
                        isDirectory: itemTemplate.contentType == .folder,
                        size: 0,
                        modified: ISO8601DateFormatter().string(from: Date()),
                        mimeType: nil,
                        etag: "new"
                    )
                }

                let createdItem = FileProviderItem(record: record)
                progress.completedUnitCount = 100
                completionHandler(createdItem, [], false, nil)
            } catch {
                progress.completedUnitCount = 100
                completionHandler(nil, [], false, error)
            }
        }

        return progress
    }

    public func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        Task {
            do {
                let record: RemoteItemRecord
                if let url = newContents {
                    record = try await self.apiClient.uploadFile(path: item.itemIdentifier.rawValue, from: url)
                } else {
                    record = try await self.apiClient.fetchItem(path: item.itemIdentifier.rawValue)
                }

                let updatedItem = FileProviderItem(record: record)
                progress.completedUnitCount = 100
                completionHandler(updatedItem, [], false, nil)
            } catch {
                progress.completedUnitCount = 100
                completionHandler(nil, [], false, error)
            }
        }

        return progress
    }

    public func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        Task {
            do {
                try await self.apiClient.deleteItem(path: identifier.rawValue)
                progress.completedUnitCount = 1
                completionHandler(nil)
            } catch {
                progress.completedUnitCount = 1
                completionHandler(error)
            }
        }

        return progress
    }

    public func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        return FileEnumerator(containerItemIdentifier: containerItemIdentifier)
    }
}
