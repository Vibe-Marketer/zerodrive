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
        NSLog("[ZeroDriveFP] enumerateChanges for container %@ from anchor", containerItemIdentifier.rawValue)
        Task {
            do {
                if self.containerItemIdentifier == .trashContainer {
                    observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                    return
                }

                let anchorString = String(data: anchor.rawValue, encoding: .utf8) ?? ""
                let anchorTimestamp: String
                if let epoch = Double(anchorString) {
                    let date = Date(timeIntervalSince1970: epoch)
                    let iso = ISO8601DateFormatter()
                    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    anchorTimestamp = iso.string(from: date)
                } else {
                    anchorTimestamp = anchorString
                }

                let activities = try await self.apiClient.fetchActivities(limit: 100)
                let sortedActivities = activities.sorted { $0.timestamp < $1.timestamp }

                let newActivities: [RemoteActivityRecord]
                if anchorTimestamp.isEmpty {
                    newActivities = sortedActivities
                } else {
                    newActivities = sortedActivities.filter { $0.timestamp > anchorTimestamp }
                }

                var updatedItemMap: [NSFileProviderItemIdentifier: NSFileProviderItemProtocol] = [:]
                var deletedItemIds: Set<NSFileProviderItemIdentifier> = []

                for act in newActivities {
                    switch act.action {
                    case "create_file", "write_file", "edit_file":
                        if let path = act.path, self.isPathRelevant(path) {
                            let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                            let itemId = NSFileProviderItemIdentifier(cleanPath)
                            deletedItemIds.remove(itemId)
                            do {
                                let record = try await self.apiClient.fetchItem(path: cleanPath)
                                let item = FileProviderItem(record: record)
                                updatedItemMap[itemId] = item
                            } catch {
                                NSLog("[ZeroDriveFP] Item fetch failed for update path %@: %@", cleanPath, error.localizedDescription)
                            }
                        }
                    case "delete_file":
                        if let path = act.path, self.isPathRelevant(path) {
                            let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                            let itemId = NSFileProviderItemIdentifier(cleanPath)
                            updatedItemMap.removeValue(forKey: itemId)
                            deletedItemIds.insert(itemId)
                        }
                    case "move_file":
                        if let src = act.source, self.isPathRelevant(src) {
                            let cleanSrc = src.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                            let srcId = NSFileProviderItemIdentifier(cleanSrc)
                            updatedItemMap.removeValue(forKey: srcId)
                            deletedItemIds.insert(srcId)
                        }
                        if let dst = act.destination, self.isPathRelevant(dst) {
                            let cleanDst = dst.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                            let dstId = NSFileProviderItemIdentifier(cleanDst)
                            deletedItemIds.remove(dstId)
                            do {
                                let record = try await self.apiClient.fetchItem(path: cleanDst)
                                let item = FileProviderItem(record: record)
                                updatedItemMap[dstId] = item
                            } catch {
                                NSLog("[ZeroDriveFP] Item fetch failed for move destination %@: %@", cleanDst, error.localizedDescription)
                            }
                        }
                    case "copy_file":
                        if let dst = act.destination, self.isPathRelevant(dst) {
                            let cleanDst = dst.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                            let dstId = NSFileProviderItemIdentifier(cleanDst)
                            deletedItemIds.remove(dstId)
                            do {
                                let record = try await self.apiClient.fetchItem(path: cleanDst)
                                let item = FileProviderItem(record: record)
                                updatedItemMap[dstId] = item
                            } catch {
                                NSLog("[ZeroDriveFP] Item fetch failed for copy destination %@: %@", cleanDst, error.localizedDescription)
                            }
                        }
                    default:
                        break
                    }
                }

                if !updatedItemMap.isEmpty {
                    let items = Array(updatedItemMap.values)
                    NSLog("[ZeroDriveFP] enumerateChanges didUpdate %d item(s) in %@", items.count, self.containerItemIdentifier.rawValue)
                    observer.didUpdate(items)
                }

                if !deletedItemIds.isEmpty {
                    let ids = Array(deletedItemIds)
                    NSLog("[ZeroDriveFP] enumerateChanges didDelete %d item(s) in %@", ids.count, self.containerItemIdentifier.rawValue)
                    observer.didDeleteItems(withIdentifiers: ids)
                }

                let latestTimestamp = newActivities.last?.timestamp ?? anchorTimestamp
                let nextAnchorStr: String
                if !latestTimestamp.isEmpty {
                    nextAnchorStr = latestTimestamp
                } else {
                    let iso = ISO8601DateFormatter()
                    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    nextAnchorStr = iso.string(from: Date())
                }

                let nextAnchor = NSFileProviderSyncAnchor(nextAnchorStr.data(using: .utf8)!)
                observer.finishEnumeratingChanges(upTo: nextAnchor, moreComing: false)
            } catch {
                NSLog("[ZeroDriveFP] enumerateChanges error: %@", error.localizedDescription)
                observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            }
        }
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let initialDate = Date().addingTimeInterval(-5.0)
        let anchorStr = isoFormatter.string(from: initialDate)
        completionHandler(NSFileProviderSyncAnchor(anchorStr.data(using: .utf8)!))
    }

    private func isPathRelevant(_ rawPath: String) -> Bool {
        if self.containerItemIdentifier == .workingSet {
            return true
        }
        let clean = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parentIdentifier: NSFileProviderItemIdentifier
        if let lastSlash = clean.lastIndex(of: "/") {
            let parentPath = String(clean[..<lastSlash])
            parentIdentifier = NSFileProviderItemIdentifier(parentPath)
        } else {
            parentIdentifier = .rootContainer
        }
        return parentIdentifier == self.containerItemIdentifier
    }
}
