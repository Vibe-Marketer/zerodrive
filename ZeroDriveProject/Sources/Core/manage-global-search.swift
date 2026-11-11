import Foundation
import AppKit

public enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case everything = "Everything"
    case nameOnly = "Name Matches"

    public var id: String { rawValue }
}

public enum DateModifiedFilter: String, CaseIterable, Identifiable, Sendable {
    case any = "Any Date"
    case today = "Today"
    case pastWeek = "Past 7 Days"
    case pastMonth = "Past 30 Days"
    case pastYear = "Past Year"

    public var id: String { rawValue }
}

public enum FileSizeFilter: String, CaseIterable, Identifiable, Sendable {
    case any = "Any Size"
    case tiny = "Tiny (< 1 MB)"
    case small = "Small (1 – 10 MB)"
    case medium = "Medium (10 – 100 MB)"
    case large = "Large (100 MB – 1 GB)"
    case huge = "Huge (> 1 GB)"

    public var id: String { rawValue }

    public func matches(sizeBytes: Int64) -> Bool {
        switch self {
        case .any:
            return true
        case .tiny:
            return sizeBytes < 1_000_000
        case .small:
            return sizeBytes >= 1_000_000 && sizeBytes < 10_000_000
        case .medium:
            return sizeBytes >= 10_000_000 && sizeBytes < 100_000_000
        case .large:
            return sizeBytes >= 100_000_000 && sizeBytes < 1_000_000_000
        case .huge:
            return sizeBytes >= 1_000_000_000
        }
    }
}

public enum SearchSortOption: String, CaseIterable, Identifiable, Sendable {
    case relevance = "Best Match"
    case dateModifiedDescending = "Date Modified (Newest)"
    case dateModifiedAscending = "Date Modified (Oldest)"
    case sizeDescending = "Size (Largest)"
    case sizeAscending = "Size (Smallest)"
    case nameAscending = "Name (A to Z)"
    case nameDescending = "Name (Z to A)"
    case kind = "Kind / Type"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .relevance: return "sparkles"
        case .dateModifiedDescending: return "arrow.down"
        case .dateModifiedAscending: return "arrow.up"
        case .sizeDescending: return "arrow.down.circle"
        case .sizeAscending: return "arrow.up.circle"
        case .nameAscending: return "textformat.characters"
        case .nameDescending: return "textformat.characters"
        case .kind: return "square.grid.2x2"
        }
    }
}

public enum SearchMode: String, CaseIterable, Identifiable, Sendable {
    case hybrid = "Smart Search"
    case semantic = "Concept"
    case regular = "Exact Name"

    public var id: String { rawValue }
}

public enum FileCategory: String, CaseIterable, Identifiable, Sendable {
    case all = "Any Kind"
    case documents = "Documents"
    case media = "Video & Audio"
    case images = "Images"
    case code = "Code & Data"
    case archives = "Archives"
    case folders = "Folders"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .documents: return "doc.text.fill"
        case .media: return "play.rectangle.fill"
        case .images: return "photo.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .archives: return "archivebox.fill"
        case .folders: return "folder.fill"
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
    public let fullPath: String
    public let fullURL: URL
    public let sizeBytes: Int64
    public let isFolder: Bool
    public let modifiedDate: Date
    public let score: Double
    public let matchType: SearchMatchType
    public let matchedReason: String
    public let category: FileCategory
    public let ext: String

    public init(
        name: String,
        relativePath: String,
        fullPath: String,
        sizeBytes: Int64,
        isFolder: Bool,
        modifiedDate: Date,
        score: Double,
        matchType: SearchMatchType,
        matchedReason: String,
        category: FileCategory,
        ext: String
    ) {
        self.id = fullPath
        self.name = name
        self.relativePath = relativePath
        self.fullPath = fullPath
        // Use explicit isDirectory to avoid expensive filesystem lstat RPC
        self.fullURL = URL(fileURLWithPath: fullPath, isDirectory: isFolder)
        self.sizeBytes = sizeBytes
        self.isFolder = isFolder
        self.modifiedDate = modifiedDate
        self.score = score
        self.matchType = matchType
        self.matchedReason = matchedReason
        self.category = category
        self.ext = ext
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    public var iconName: String {
        if isFolder { return "folder.fill" }
        switch category {
        case .documents: return "doc.text.fill"
        case .media:
            return ["mp3", "wav", "m4a", "aac", "flac"].contains(ext) ? "music.note" : "film.fill"
        case .images: return "photo.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .archives: return "archivebox.fill"
        case .folders: return "folder.fill"
        case .all: return "doc.fill"
        }
    }
}

@MainActor
public final class ManageGlobalSearch: ObservableObject {
    public static let shared = ManageGlobalSearch()

    @Published public var query: String = ""
    @Published public var searchScope: SearchScope = .everything
    @Published public var selectedCategory: FileCategory = .all
    @Published public var selectedExtension: String = ""
    @Published public var dateFilter: DateModifiedFilter = .any
    @Published public var sizeFilter: FileSizeFilter = .any
    @Published public var sortOption: SearchSortOption = .relevance
    @Published public var searchMode: SearchMode = .hybrid

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
        let fullPath: String
        let sizeBytes: Int64
        let isFolder: Bool
        let modifiedDate: Date
        let category: FileCategory
        let ext: String
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
        let tokens: [String]?
    }

    private struct PersistedIndex: Codable {
        let version: Int
        let timestamp: Double
        let records: [PersistedRecord]
    }

    // Concept dictionary mapping topics and intents to related vocabulary
    private nonisolated static let semanticConceptMap: [String: Set<String>] = [
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
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.loadCacheFromDisk()
        }
    }

    public func loadCacheFromDisk() async {
        let cache = self.cacheURL
        let parsed: [IndexedFileRecord]? = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: cache),
                  let persisted = try? JSONDecoder().decode(PersistedIndex.self, from: data) else {
                return nil
            }
            // Parse into pure memory records without hitting disk or NFS via URL(fileURLWithPath:)
            return persisted.records.map { rec in
                let ext = (rec.name as NSString).pathExtension.lowercased()
                return IndexedFileRecord(
                    name: rec.name,
                    relativePath: rec.relativePath,
                    fullPath: rec.fullPath,
                    sizeBytes: rec.sizeBytes,
                    isFolder: rec.isFolder,
                    modifiedDate: Date(timeIntervalSince1970: rec.modifiedTimeInterval),
                    category: FileCategory(rawValue: rec.category) ?? .all,
                    ext: ext,
                    tokens: Set(rec.tokens ?? [])
                )
            }
        }.value

        guard let parsed else { return }

        await MainActor.run {
            self.indexedFiles = parsed
            self.totalIndexedCount = parsed.count
            if !self.query.isEmpty {
                self.executeSearch()
            }
        }
    }

    /// Indexes My Drive directly from S3 via rclone lsjson (bypasses go-nfs so the NFS mount never stalls!)
    public func prewarmIndex() async {
        guard !isIndexing else { return }
        isIndexing = true

        let mount = RcloneDaemonSupervisor.shared.mountPoint.appendingPathComponent("My Drive")
        let cacheFile = self.cacheURL
        let rcloneBin = RcloneDaemonSupervisor.shared.resolveRcloneBinary()
        let meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
        let configPath = MultiCloudCombineBuilder.shared.configPath.path

        Task.detached(priority: .utility) {
            guard let rclone = rcloneBin else {
                await MainActor.run { self.isIndexing = false }
                return
            }

            let proc = Process()
            proc.executableURL = rclone
            proc.arguments = [
                "lsjson",
                "-R",
                "--fast-list",
                "--no-mimetype",
                "--use-server-modtime",
                "--disable-http2",
                "primary_vault:\(meta.bucketAndPrefix)",
                "--config=\(configPath)",
                "--exclude=**/.git/**",
                "--exclude=**/node_modules/**",
                "--exclude=**/scroll-sequences/**",
                "--exclude=**/__pycache__/**",
                "--exclude=**/.obsidian/**",
                "--exclude=**/kf/**",
                "--exclude=**/.runitback/**",
                "--exclude=**/.transcode-cache/**",
                "--exclude=**/.DS_Store",
                "--exclude=**/._*"
            ]
            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = Pipe()

            var rawData = Data()
            do {
                try proc.run()
                rawData = outPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
            } catch {
                await MainActor.run { self.isIndexing = false }
                return
            }

            guard proc.terminationStatus == 0,
                  let entries = try? JSONSerialization.jsonObject(with: rawData) as? [[String: Any]] else {
                await MainActor.run { self.isIndexing = false }
                return
            }

            var records: [IndexedFileRecord] = []
            records.reserveCapacity(entries.count)
            let mountBasePath = mount.path.hasSuffix("/") ? String(mount.path.dropLast()) : mount.path
            let isoFrac = ISO8601DateFormatter()
            isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoBasic = ISO8601DateFormatter()

            for entry in entries {
                guard let rel = entry["Path"] as? String, !rel.isEmpty else { continue }
                let name = (entry["Name"] as? String) ?? (rel as NSString).lastPathComponent
                if name.hasPrefix(".") { continue }

                let isDir = (entry["IsDir"] as? Bool) ?? false
                let size = (entry["Size"] as? NSNumber)?.int64Value ?? 0
                let mdate: Date = {
                    if let modStr = entry["ModTime"] as? String {
                        return isoFrac.date(from: modStr) ?? isoBasic.date(from: modStr) ?? Date()
                    }
                    return Date()
                }()
                let fullPath = "\(mountBasePath)/\(rel)"
                let category = Self.classifyCategory(filename: name, isDirectory: isDir)
                let ext = (name as NSString).pathExtension.lowercased()
                let tokens = Self.tokenize(text: name + " " + rel)

                records.append(IndexedFileRecord(
                    name: name,
                    relativePath: rel,
                    fullPath: fullPath,
                    sizeBytes: max(0, size),
                    isFolder: isDir,
                    modifiedDate: mdate,
                    category: category,
                    ext: ext,
                    tokens: tokens
                ))
            }

            let finalRecords = records

            // Save to disk cache
            let persisted = PersistedIndex(
                version: 2,
                timestamp: Date().timeIntervalSince1970,
                records: finalRecords.map { r in
                    PersistedRecord(
                        name: r.name,
                        relativePath: r.relativePath,
                        fullPath: r.fullPath,
                        sizeBytes: r.sizeBytes,
                        isFolder: r.isFolder,
                        modifiedTimeInterval: r.modifiedDate.timeIntervalSince1970,
                        category: r.category.rawValue,
                        tokens: nil
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
                if !self.query.isEmpty {
                    self.executeSearch()
                }
            }
        }
    }

    private var searchDebounceTask: Task<Void, Never>?

    /// Performs the search with full Finder-grade filtering and sorting
    public func executeSearch() {
        searchDebounceTask?.cancel()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse query tokens and inline syntax like "ext:pdf", "kind:image", "size:>10m"
        var parsedQuery = trimmedQuery.lowercased()
        var inlineExt: String? = nil
        var inlineCategory: FileCategory? = nil
        var inlineMinSize: Int64? = nil
        var inlineMaxSize: Int64? = nil

        let words = parsedQuery.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var cleanKeywords: [String] = []

        for word in words {
            if word.hasPrefix("ext:") || word.hasPrefix("type:") {
                let parts = word.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    inlineExt = String(parts[1]).trimmingCharacters(in: .punctuationCharacters)
                }
            } else if word.hasPrefix("kind:") {
                let parts = word.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let kindStr = String(parts[1])
                    if kindStr.contains("doc") { inlineCategory = .documents }
                    else if kindStr.contains("vid") || kindStr.contains("media") || kindStr.contains("audio") { inlineCategory = .media }
                    else if kindStr.contains("img") || kindStr.contains("pic") || kindStr.contains("photo") { inlineCategory = .images }
                    else if kindStr.contains("code") || kindStr.contains("dev") { inlineCategory = .code }
                    else if kindStr.contains("zip") || kindStr.contains("arch") { inlineCategory = .archives }
                    else if kindStr.contains("fold") || kindStr.contains("dir") { inlineCategory = .folders }
                }
            } else if word.hasPrefix("size:>") || word.hasPrefix("size:>=") {
                let val = word.replacingOccurrences(of: "size:>=", with: "").replacingOccurrences(of: "size:>", with: "")
                inlineMinSize = Self.parseSizeString(val)
            } else if word.hasPrefix("size:<") || word.hasPrefix("size:<=") {
                let val = word.replacingOccurrences(of: "size:<=", with: "").replacingOccurrences(of: "size:<", with: "")
                inlineMaxSize = Self.parseSizeString(val)
            } else {
                cleanKeywords.append(word)
            }
        }

        let effectiveRawQuery = cleanKeywords.joined(separator: " ")

        // If no query and no filters, clear results
        let hasActiveFilter = selectedCategory != .all ||
                              !selectedExtension.isEmpty ||
                              dateFilter != .any ||
                              sizeFilter != .any ||
                              inlineExt != nil ||
                              inlineCategory != nil ||
                              inlineMinSize != nil ||
                              inlineMaxSize != nil

        if effectiveRawQuery.isEmpty && !hasActiveFilter {
            results = []
            isSearching = false
            searchDurationMs = 0.0
            return
        }

        isSearching = true
        let files = self.indexedFiles
        let mode = self.searchMode
        let categoryFilter = inlineCategory ?? self.selectedCategory
        let extFilter = inlineExt ?? self.selectedExtension.lowercased().trimmingCharacters(in: .punctuationCharacters)
        let scope = self.searchScope
        let dateFilter = self.dateFilter
        let sizeFilter = self.sizeFilter
        let sortOption = self.sortOption

        searchDebounceTask = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 35_000_000)
            if Task.isCancelled { return }

            let t0 = CFAbsoluteTimeGetCurrent()
            let queryTokens = Self.tokenize(text: effectiveRawQuery)

            // Generate semantic expanded terms
            var expandedConcepts: Set<String> = []
            if mode != .regular && !effectiveRawQuery.isEmpty {
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
            let now = Date()
            let cal = Calendar.current

            for item in files {
                if Task.isCancelled { return }

                // 1. Kind / Category filter
                if categoryFilter != .all {
                    if categoryFilter == .folders {
                        if !item.isFolder { continue }
                    } else if item.category != categoryFilter {
                        continue
                    }
                }

                // 2. Specific Extension filter
                if !extFilter.isEmpty {
                    if item.isFolder || item.ext != extFilter {
                        continue
                    }
                }

                // 3. File Size filter
                if sizeFilter != .any && !sizeFilter.matches(sizeBytes: item.sizeBytes) {
                    continue
                }
                if let minSize = inlineMinSize, item.sizeBytes < minSize {
                    continue
                }
                if let maxSize = inlineMaxSize, item.sizeBytes > maxSize {
                    continue
                }

                // 4. Date Modified filter
                if dateFilter != .any {
                    switch dateFilter {
                    case .today:
                        if item.modifiedDate < cal.startOfDay(for: now) { continue }
                    case .pastWeek:
                        guard let cutoff = cal.date(byAdding: .day, value: -7, to: now), item.modifiedDate >= cutoff else { continue }
                    case .pastMonth:
                        guard let cutoff = cal.date(byAdding: .day, value: -30, to: now), item.modifiedDate >= cutoff else { continue }
                    case .pastYear:
                        guard let cutoff = cal.date(byAdding: .year, value: -1, to: now), item.modifiedDate >= cutoff else { continue }
                    case .any:
                        break
                    }
                }

                // If query is empty but filter is active (e.g. show all .mov or all >1GB), include all matches
                if effectiveRawQuery.isEmpty {
                    scoredItems.append(SearchResultItem(
                        name: item.name,
                        relativePath: item.relativePath,
                        fullPath: item.fullPath,
                        sizeBytes: item.sizeBytes,
                        isFolder: item.isFolder,
                        modifiedDate: item.modifiedDate,
                        score: 100.0,
                        matchType: .tag,
                        matchedReason: "Filtered by properties",
                        category: item.category,
                        ext: item.ext
                    ))
                    continue
                }

                let lowerName = item.name.lowercased()
                let lowerPath = item.relativePath.lowercased()

                var score: Double = 0.0
                var matchType: SearchMatchType = .exact
                var reason = ""

                // Exact Filename Match
                if lowerName == effectiveRawQuery {
                    score = 100.0
                    matchType = .exact
                    reason = "Exact filename match"
                } else if lowerName.hasPrefix(effectiveRawQuery) {
                    score = 90.0
                    matchType = .prefix
                    reason = "Filename starts with '\(effectiveRawQuery)'"
                } else if lowerName.contains(effectiveRawQuery) {
                    score = 80.0
                    matchType = .prefix
                    reason = "Filename contains '\(effectiveRawQuery)'"
                } else if scope == .everything && lowerPath.contains(effectiveRawQuery) {
                    score = 70.0
                    matchType = .prefix
                    reason = "Path contains '\(effectiveRawQuery)'"
                }

                // Token Matching
                if score < 70.0 {
                    var matchedTokenCount = 0
                    for token in queryTokens {
                        if lowerName.contains(token) || (scope == .everything && (item.tokens.contains(token) || lowerPath.contains(token))) {
                            matchedTokenCount += 1
                        }
                    }
                    if matchedTokenCount > 0 {
                        let ratio = Double(matchedTokenCount) / Double(queryTokens.count)
                        score = max(score, 50.0 + (ratio * 25.0))
                        matchType = .prefix
                        reason = "Matched \(matchedTokenCount) keyword(s)"
                    }
                }

                // Concept Intent Scoring
                if scope == .everything && !expandedConcepts.isEmpty {
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
                        fullPath: item.fullPath,
                        sizeBytes: item.sizeBytes,
                        isFolder: item.isFolder,
                        modifiedDate: item.modifiedDate,
                        score: score,
                        matchType: matchType,
                        matchedReason: reason,
                        category: item.category,
                        ext: item.ext
                    ))
                }
            }

            if Task.isCancelled { return }

            // 5. Sort according to SearchSortOption
            switch sortOption {
            case .relevance:
                scoredItems.sort {
                    if abs($0.score - $1.score) > 0.01 {
                        return $0.score > $1.score
                    }
                    return $0.modifiedDate > $1.modifiedDate
                }
            case .dateModifiedDescending:
                scoredItems.sort { $0.modifiedDate > $1.modifiedDate }
            case .dateModifiedAscending:
                scoredItems.sort { $0.modifiedDate < $1.modifiedDate }
            case .sizeDescending:
                scoredItems.sort { $0.sizeBytes > $1.sizeBytes }
            case .sizeAscending:
                scoredItems.sort { $0.sizeBytes < $1.sizeBytes }
            case .nameAscending:
                scoredItems.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            case .nameDescending:
                scoredItems.sort { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
            case .kind:
                scoredItems.sort {
                    if $0.category.rawValue != $1.category.rawValue {
                        return $0.category.rawValue < $1.category.rawValue
                    }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }

            let topResults = Array(scoredItems.prefix(300))
            let duration = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0

            await MainActor.run {
                self.results = topResults
                self.searchDurationMs = duration
                self.isSearching = false
            }
        }
    }

    private nonisolated static func parseSizeString(_ str: String) -> Int64? {
        let clean = str.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if clean.hasSuffix("g") || clean.hasSuffix("gb") {
            let num = clean.replacingOccurrences(of: "gb", with: "").replacingOccurrences(of: "g", with: "")
            if let d = Double(num) { return Int64(d * 1_000_000_000) }
        } else if clean.hasSuffix("m") || clean.hasSuffix("mb") {
            let num = clean.replacingOccurrences(of: "mb", with: "").replacingOccurrences(of: "m", with: "")
            if let d = Double(num) { return Int64(d * 1_000_000) }
        } else if clean.hasSuffix("k") || clean.hasSuffix("kb") {
            let num = clean.replacingOccurrences(of: "kb", with: "").replacingOccurrences(of: "k", with: "")
            if let d = Double(num) { return Int64(d * 1_000) }
        } else if let num = Int64(clean) {
            return num
        }
        return nil
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

    public func clearAllFilters() {
        query = ""
        selectedCategory = .all
        selectedExtension = ""
        dateFilter = .any
        sizeFilter = .any
        sortOption = .relevance
        executeSearch()
    }

    private nonisolated static func classifyCategory(filename: String, isDirectory: Bool) -> FileCategory {
        if isDirectory { return .folders }
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
