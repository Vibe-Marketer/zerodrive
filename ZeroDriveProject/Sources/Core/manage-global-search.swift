import Foundation
import AppKit

public enum SearchMode: String, CaseIterable, Identifiable, Sendable {
    case hybrid = "Smart Search"
    case semantic = "Concept"
    case regular = "Exact Name"

    public var id: String { rawValue }
}

public enum FileCategory: String, CaseIterable, Identifiable, Sendable {
    case all = "All Files"
    case documents = "Documents"
    case media = "Video & Audio"
    case images = "Images"
    case code = "Code & Data"
    case archives = "Archives"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .documents: return "doc.text.fill"
        case .media: return "play.rectangle.fill"
        case .images: return "photo.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .archives: return "archivebox.fill"
        }
    }
}

public enum SearchMatchType: String, Sendable {
    case exact = "Exact"
    case prefix = "Name Match"
    case semantic = "Concept"
    case tag = "Category"
}

public struct SearchResultItem: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let relativePath: String
    public let fullURL: URL
    public let sizeBytes: Int64
    public let isFolder: Bool
    public let modifiedDate: Date
    public let score: Double
    public let matchType: SearchMatchType
    public let matchedReason: String
    public let category: FileCategory

    public init(
        name: String,
        relativePath: String,
        fullURL: URL,
        sizeBytes: Int64,
        isFolder: Bool,
        modifiedDate: Date,
        score: Double,
        matchType: SearchMatchType,
        matchedReason: String,
        category: FileCategory
    ) {
        self.id = fullURL.path
        self.name = name
        self.relativePath = relativePath
        self.fullURL = fullURL
        self.sizeBytes = sizeBytes
        self.isFolder = isFolder
        self.modifiedDate = modifiedDate
        self.score = score
        self.matchType = matchType
        self.matchedReason = matchedReason
        self.category = category
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    public var iconName: String {
        if isFolder { return "folder.fill" }
        switch category {
        case .documents: return "doc.text.fill"
        case .media:
            let ext = (name as NSString).pathExtension.lowercased()
            return ["mp3", "wav", "m4a", "aac", "flac"].contains(ext) ? "music.note" : "film.fill"
        case .images: return "photo.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .archives: return "archivebox.fill"
        case .all: return "doc.fill"
        }
    }
}

@MainActor
public final class ManageGlobalSearch: ObservableObject {
    public static let shared = ManageGlobalSearch()

    @Published public var query: String = ""
    @Published public var searchMode: SearchMode = .hybrid
    @Published public var selectedCategory: FileCategory = .all
    @Published public private(set) var results: [SearchResultItem] = []
    @Published public private(set) var isSearching: Bool = false
    @Published public private(set) var isIndexing: Bool = false
    @Published public private(set) var totalIndexedCount: Int = 0
    @Published public private(set) var searchDurationMs: Double = 0.0

    private var indexedFiles: [IndexedFileRecord] = []
    private var lastIndexDate: Date? = nil

    private let cacheURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/rclone/zerodrive-search-index.json")

    private struct IndexedFileRecord: Sendable {
        let name: String
        let relativePath: String
        let fullURL: URL
        let sizeBytes: Int64
        let isFolder: Bool
        let modifiedDate: Date
        let category: FileCategory
        let tokens: Set<String>
    }

    private struct PersistedRecord: Codable {
        let name: String
        let relativePath: String
        let fullPath: String
        let sizeBytes: Int64
        let isFolder: Bool
        let modifiedTimeInterval: Double
        let category: String
        let tokens: [String]
    }

    private struct PersistedIndex: Codable {
        let version: Int
        let timestamp: Double
        let records: [PersistedRecord]
    }

    // Concept dictionary mapping topics and intents to related vocabulary
    private static let semanticConceptMap: [String: Set<String>] = [
        "finance": ["invoice", "receipt", "tax", "1099", "w2", "statement", "report", "accounting", "ledger", "stripe", "payout", "revenue", "bill", "expense", "budget", "payroll"],
        "tax": ["1099", "w2", "deduction", "irs", "return", "cpa", "filing", "accounting", "statement", "schedule"],
        "invoice": ["receipt", "bill", "payment", "stripe", "vendor", "due", "paid", "remittance"],
        "video": ["recording", "screen", "capture", "mov", "mp4", "mkv", "footage", "clip", "broll", "obs", "loom", "screencast", "zoom", "cut", "edit", "reel"],
        "screen recording": ["screencast", "screen", "capture", "recording", "obs", "loom", "cleanshot", "shot", "recording"],
        "audio": ["podcast", "voiceover", "voice", "sound", "track", "music", "song", "mp3", "wav", "m4a", "stem", "interview"],
        "photo": ["image", "picture", "screenshot", "shot", "png", "jpg", "jpeg", "svg", "graphic", "logo", "thumbnail", "avatar", "asset"],
        "logo": ["brand", "icon", "vector", "svg", "png", "mark", "lockup", "badge", "crest"],
        "code": ["component", "script", "app", "hook", "api", "function", "swift", "python", "py", "typescript", "ts", "javascript", "js", "tsx", "jsx", "html", "css", "json", "rust", "go", "sql"],
        "contract": ["agreement", "nda", "signed", "legal", "terms", "clause", "signature", "client", "master"],
        "backup": ["archive", "dump", "export", "zip", "tar", "gz", "snapshot", "clone", "vault"],
        "design": ["mockup", "figma", "sketch", "ui", "ux", "wireframe", "layout", "canvas", "brand", "asset"]
    ]

    private init() {
        loadCacheFromDisk()
        Task {
            await prewarmIndex()
        }
    }

    private func loadCacheFromDisk() {
        guard let data = try? Data(contentsOf: cacheURL),
              let persisted = try? JSONDecoder().decode(PersistedIndex.self, from: data) else {
            return
        }
        self.indexedFiles = persisted.records.map { rec in
            IndexedFileRecord(
                name: rec.name,
                relativePath: rec.relativePath,
                fullURL: URL(fileURLWithPath: rec.fullPath),
                sizeBytes: rec.sizeBytes,
                isFolder: rec.isFolder,
                modifiedDate: Date(timeIntervalSince1970: rec.modifiedTimeInterval),
                category: FileCategory(rawValue: rec.category) ?? .all,
                tokens: Set(rec.tokens)
            )
        }
        self.totalIndexedCount = self.indexedFiles.count
    }

    /// Crawls My Drive into RAM memory for instant sub-millisecond querying
    public func prewarmIndex() async {
        guard !isIndexing else { return }
        isIndexing = true

        let mount = RcloneDaemonSupervisor.shared.mountPoint.appendingPathComponent("My Drive")
        let cacheFile = self.cacheURL

        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            guard fm.fileExists(atPath: mount.path) else {
                await MainActor.run { self.isIndexing = false }
                return
            }

            var records: [IndexedFileRecord] = []
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
            let mountPathPrefix = mount.path.hasSuffix("/") ? mount.path : mount.path + "/"

            // Exclude heavy noisy internal cache and build folders
            let noisyFolders: Set<String> = [".git", "node_modules", "scroll-sequences", "__pycache__", ".obsidian", "kf", ".runitback"]

            // List top-level items in My Drive
            let topItems = (try? fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []

            var lastReportedCount = 0

            for topItem in topItems {
                let topName = topItem.lastPathComponent
                if topName.hasPrefix(".") { continue }

                guard let res = try? topItem.resourceValues(forKeys: Set(keys)) else { continue }
                let isDir = res.isDirectory ?? false
                let size = Int64(res.fileSize ?? 0)
                let mdate = res.contentModificationDate ?? Date()
                let rel = topItem.path.replacingOccurrences(of: mountPathPrefix, with: "")
                let category = Self.classifyCategory(filename: topName, isDirectory: isDir)
                let tokens = Self.tokenize(text: topName + " " + rel)

                records.append(IndexedFileRecord(
                    name: topName,
                    relativePath: rel,
                    fullURL: topItem,
                    sizeBytes: size,
                    isFolder: isDir,
                    modifiedDate: mdate,
                    category: category,
                    tokens: tokens
                ))

                if !isDir { continue }
                if noisyFolders.contains(topName) { continue }

                // Enumerate subfolder recursively with robust error handler
                if let enumerator = fm.enumerator(
                    at: topItem,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { _, _ in true }
                ) {
                    while let fileURL = enumerator.nextObject() as? URL {
                        let name = fileURL.lastPathComponent
                        if name.hasPrefix(".") { continue }

                        guard let subRes = try? fileURL.resourceValues(forKeys: Set(keys)) else { continue }
                        let subIsDir = subRes.isDirectory ?? false
                        if subIsDir && noisyFolders.contains(name) {
                            enumerator.skipDescendants()
                            continue
                        }

                        let subSize = Int64(subRes.fileSize ?? 0)
                        let subDate = subRes.contentModificationDate ?? Date()
                        let subRel = fileURL.path.replacingOccurrences(of: mountPathPrefix, with: "")
                        let subCategory = Self.classifyCategory(filename: name, isDirectory: subIsDir)
                        let subTokens = Self.tokenize(text: name + " " + subRel)

                        records.append(IndexedFileRecord(
                            name: name,
                            relativePath: subRel,
                            fullURL: fileURL,
                            sizeBytes: subSize,
                            isFolder: subIsDir,
                            modifiedDate: subDate,
                            category: subCategory,
                            tokens: subTokens
                        ))

                        if records.count - lastReportedCount >= 500 {
                            lastReportedCount = records.count
                            let currentCount = records.count
                            await MainActor.run {
                                self.totalIndexedCount = currentCount
                            }
                        }
                    }
                }
            }

            let finalRecords = records

            // Save to disk cache
            let persisted = PersistedIndex(
                version: 1,
                timestamp: Date().timeIntervalSince1970,
                records: finalRecords.map { r in
                    PersistedRecord(
                        name: r.name,
                        relativePath: r.relativePath,
                        fullPath: r.fullURL.path,
                        sizeBytes: r.sizeBytes,
                        isFolder: r.isFolder,
                        modifiedTimeInterval: r.modifiedDate.timeIntervalSince1970,
                        category: r.category.rawValue,
                        tokens: Array(r.tokens)
                    )
                }
            )

            if let data = try? JSONEncoder().encode(persisted) {
                try? data.write(to: cacheFile, options: .atomic)
            }

            await MainActor.run {
                self.indexedFiles = finalRecords
                self.totalIndexedCount = finalRecords.count
                self.lastIndexDate = Date()
                self.isIndexing = false
                // Re-execute current search with fresh index
                if !self.query.isEmpty {
                    self.executeSearch()
                }
            }
        }
    }

    /// Performs the search (regular, semantic, or hybrid)
    public func executeSearch() {
        let t0 = CFAbsoluteTimeGetCurrent()
        let rawQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !rawQuery.isEmpty else {
            results = []
            searchDurationMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            return
        }

        isSearching = true
        let queryTokens = Self.tokenize(text: rawQuery)
        let mode = self.searchMode
        let categoryFilter = self.selectedCategory

        // Generate semantic expanded terms
        var expandedConcepts: Set<String> = []
        if mode != .regular {
            for qToken in queryTokens {
                for (concept, synonyms) in Self.semanticConceptMap {
                    if concept.contains(qToken) || qToken.contains(concept) || synonyms.contains(qToken) {
                        expandedConcepts.formUnion(synonyms)
                        expandedConcepts.insert(concept)
                    }
                }
            }
        }

        var scoredItems: [SearchResultItem] = []

        for item in indexedFiles {
            // Apply category filter if selected
            if categoryFilter != .all && item.category != categoryFilter {
                continue
            }

            let lowerName = item.name.lowercased()
            let lowerPath = item.relativePath.lowercased()

            var score: Double = 0.0
            var matchType: SearchMatchType = .exact
            var reason = ""

            // 1. Regular Exact Match Check
            if lowerName == rawQuery {
                score = 100.0
                matchType = .exact
                reason = "Exact filename match"
            } else if lowerName.hasPrefix(rawQuery) {
                score = 90.0
                matchType = .prefix
                reason = "Filename starts with '\(rawQuery)'"
            } else if lowerName.contains(rawQuery) {
                score = 80.0
                matchType = .prefix
                reason = "Filename contains '\(rawQuery)'"
            } else if lowerPath.contains(rawQuery) {
                score = 70.0
                matchType = .prefix
                reason = "Path contains '\(rawQuery)'"
            }

            // 2. Token Matching (if not exact)
            if score < 70.0 {
                var matchedTokenCount = 0
                for token in queryTokens {
                    if item.tokens.contains(token) || lowerName.contains(token) {
                        matchedTokenCount += 1
                    }
                }
                if matchedTokenCount > 0 {
                    let ratio = Double(matchedTokenCount) / Double(queryTokens.count)
                    score = max(score, 50.0 + (ratio * 25.0))
                    matchType = .prefix
                    reason = "Matched \(matchedTokenCount) search keywords"
                }
            }

            // 3. Semantic Intent Scoring (if in hybrid or semantic mode)
            if mode != .regular && !expandedConcepts.isEmpty {
                var semanticMatches = 0
                var matchedConceptWord = ""
                for conceptWord in expandedConcepts {
                    if item.tokens.contains(conceptWord) || lowerName.contains(conceptWord) || lowerPath.contains(conceptWord) {
                        semanticMatches += 1
                        if matchedConceptWord.isEmpty {
                            matchedConceptWord = conceptWord
                        }
                    }
                }

                if semanticMatches > 0 {
                    let semanticBoost = min(35.0, Double(semanticMatches) * 12.0)
                    let totalSemanticScore = 45.0 + semanticBoost
                    if totalSemanticScore > score {
                        score = totalSemanticScore
                        matchType = .semantic
                        reason = "Concept match: related to '\(matchedConceptWord)'"
                    }
                }
            }

            if score > 0 {
                scoredItems.append(SearchResultItem(
                    name: item.name,
                    relativePath: item.relativePath,
                    fullURL: item.fullURL,
                    sizeBytes: item.sizeBytes,
                    isFolder: item.isFolder,
                    modifiedDate: item.modifiedDate,
                    score: score,
                    matchType: matchType,
                    matchedReason: reason,
                    category: item.category
                ))
            }
        }

        // Sort descending by score, then recency
        scoredItems.sort {
            if abs($0.score - $1.score) > 0.01 {
                return $0.score > $1.score
            }
            return $0.modifiedDate > $1.modifiedDate
        }

        self.results = scoredItems
        self.searchDurationMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
        self.isSearching = false
    }

    /// Reveals the file or folder in Finder
    public func revealInFinder(url: URL) {
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }

    /// Opens the file with the default macOS app
    public func openFile(url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Copies path to clipboard
    public func copyPath(url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    private nonisolated static func classifyCategory(filename: String, isDirectory: Bool) -> FileCategory {
        if isDirectory { return .all }
        let ext = (filename as NSString).pathExtension.lowercased()

        switch ext {
        case "pdf", "doc", "docx", "txt", "rtf", "md", "xls", "xlsx", "csv", "numbers", "pages", "pptx", "key":
            return .documents
        case "mov", "mp4", "m4v", "mkv", "avi", "webm", "mp3", "wav", "m4a", "aac", "flac", "aiff":
            return .media
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "ai", "psd", "tiff":
            return .images
        case "swift", "py", "js", "ts", "tsx", "jsx", "json", "html", "css", "yaml", "yml", "sql", "sh", "rs", "go":
            return .code
        case "zip", "tar", "gz", "7z", "rar", "dmg", "pkg":
            return .archives
        default:
            return .all
        }
    }

    private nonisolated static func tokenize(text: String) -> Set<String> {
        let clean = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(clean.filter { $0.count >= 2 })
    }
}
