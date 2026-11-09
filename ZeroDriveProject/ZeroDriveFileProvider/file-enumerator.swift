import Foundation
import FileProvider

public class FileEnumerator: NSObject, NSFileProviderEnumerator {
    private let containerItemIdentifier: NSFileProviderItemIdentifier
    private let apiClient = ZeroDriveAPIClient.shared

    public init(containerItemIdentifier: NSFileProviderItemIdentifier) {
        self.containerItemIdentifier = containerItemIdentifier
        super.init()
    }

    public func invalidate() {}

    public func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        NSLog("[ZeroDriveFP] enumerateItems for %@", containerItemIdentifier.rawValue)
        Task {
            do {
                if self.containerItemIdentifier == .workingSet || self.containerItemIdentifier == .trashContainer {
                    observer.didEnumerate([])
                    observer.finishEnumerating(upTo: nil)
                    return
                }

                let targetPath: String
                if self.containerItemIdentifier == .rootContainer {
                    targetPath = ""
                } else {
                    targetPath = self.containerItemIdentifier.rawValue
                }

                var cursorString: String? = nil
                let initialByName = NSFileProviderPage.initialPageSortedByName as NSFileProviderPage
                let initialByDate = NSFileProviderPage.initialPageSortedByDate as NSFileProviderPage
                if page != initialByName &&
                   page != initialByDate &&
                   !page.rawValue.isEmpty {
                    cursorString = String(data: page.rawValue, encoding: .utf8)
                }

                let (records, nextCursor, hasMore) = try await self.apiClient.listFiles(
                    path: targetPath,
                    cursor: cursorString,
                    limit: 500
                )

                let items: [FileProviderItem] = records.map { FileProviderItem(record: $0) }
                observer.didEnumerate(items)

                if hasMore, let next = nextCursor, !next.isEmpty, let pageData = next.data(using: .utf8) {
                    observer.finishEnumerating(upTo: NSFileProviderPage(pageData))
                } else {
                    observer.finishEnumerating(upTo: nil)
                }
            } catch {
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    public func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let currentAnchor = "\(Int(Date().timeIntervalSince1970))".data(using: .utf8)!
        observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(currentAnchor), moreComing: false)
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let currentAnchor = "\(Int(Date().timeIntervalSince1970))".data(using: .utf8)!
        completionHandler(NSFileProviderSyncAnchor(currentAnchor))
    }
}
