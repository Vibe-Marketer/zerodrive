import SwiftUI
import AppKit

public struct GlobalSearchView: View {
    @ObservedObject private var searchManager = ManageGlobalSearch.shared
    @EnvironmentObject var supervisor: RcloneDaemonSupervisor

    @State private var hoveredItemId: String? = nil

    private let popularExtensions: [String] = [
        "pdf", "mov", "mp4", "png", "jpg", "zip", "py", "csv", "json"
    ]

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // MARK: - 1. Top Search Bar & Controls
            searchHeaderBar

            Divider()

            // MARK: - 2. Filter Pills & Stats Row
            filterAndStatsBar

            Divider()

            // MARK: - 3. Results Area
            resultsContentArea
        }
        .navigationTitle("Global Search")
    }

    // MARK: - 1. Search Header Bar
    private var searchHeaderBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)

                TextField("Search files by name, type, size, extension (e.g. ext:pdf, size:>100m)…", text: $searchManager.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .onSubmit {
                        searchManager.executeSearch()
                    }
                    .onChange(of: searchManager.query) { _ in
                        searchManager.executeSearch()
                    }

                if !searchManager.query.isEmpty {
                    Button {
                        searchManager.query = ""
                        searchManager.executeSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                // Finder-Style Scope Dropdown (Everything vs Name Matches)
                Menu {
                    ForEach(SearchScope.allCases) { scope in
                        Button {
                            searchManager.searchScope = scope
                            searchManager.executeSearch()
                        } label: {
                            HStack {
                                Text(scope.rawValue)
                                if searchManager.searchScope == scope {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: searchManager.searchScope == .nameOnly ? "character.cursor.ibeam" : "globe")
                            .font(.system(size: 11))
                        Text(searchManager.searchScope.rawValue)
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Finder-Style Size Filter Dropdown
                Menu {
                    ForEach(FileSizeFilter.allCases) { sf in
                        Button {
                            searchManager.sizeFilter = sf
                            searchManager.executeSearch()
                        } label: {
                            HStack {
                                Text(sf.rawValue)
                                if searchManager.sizeFilter == sf {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "scalemass")
                            .font(.system(size: 11))
                        Text(searchManager.sizeFilter == .any ? "Size" : searchManager.sizeFilter.rawValue)
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(searchManager.sizeFilter == .any ? Color.secondary.opacity(0.1) : Color.accentColor.opacity(0.15))
                    .foregroundStyle(searchManager.sizeFilter == .any ? Color.primary : Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Finder-Style Date Filter Dropdown
                Menu {
                    ForEach(DateModifiedFilter.allCases) { df in
                        Button {
                            searchManager.dateFilter = df
                            searchManager.executeSearch()
                        } label: {
                            HStack {
                                Text(df.rawValue)
                                if searchManager.dateFilter == df {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.system(size: 11))
                        Text(searchManager.dateFilter == .any ? "Date" : searchManager.dateFilter.rawValue)
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(searchManager.dateFilter == .any ? Color.secondary.opacity(0.1) : Color.accentColor.opacity(0.15))
                    .foregroundStyle(searchManager.dateFilter == .any ? Color.primary : Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Finder-Style Sort By Dropdown
                Menu {
                    ForEach(SearchSortOption.allCases) { opt in
                        Button {
                            searchManager.sortOption = opt
                            searchManager.executeSearch()
                        } label: {
                            HStack {
                                Text(opt.rawValue)
                                if searchManager.sortOption == opt {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 11))
                        Text(searchManager.sortOption == .relevance ? "Sort" : searchManager.sortOption.rawValue)
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(searchManager.sortOption == .relevance ? Color.secondary.opacity(0.1) : Color.accentColor.opacity(0.15))
                    .foregroundStyle(searchManager.sortOption == .relevance ? Color.primary : Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 2. Filter Pills & Extension Bar
    private var filterAndStatsBar: some View {
        VStack(spacing: 6) {
            // Category capsules & Extension chips
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(FileCategory.allCases) { cat in
                            Button {
                                searchManager.selectedCategory = cat
                                searchManager.executeSearch()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: cat.icon)
                                        .font(.system(size: 10))
                                    Text(cat.rawValue)
                                        .font(.system(size: 11, weight: searchManager.selectedCategory == cat ? .semibold : .regular))
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(searchManager.selectedCategory == cat ? Color.accentColor : Color.secondary.opacity(0.08))
                                .foregroundStyle(searchManager.selectedCategory == cat ? Color.white : Color.primary)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }

                        Divider()
                            .frame(height: 16)
                            .padding(.horizontal, 4)

                        // Extension Filters
                        Button {
                            searchManager.selectedExtension = ""
                            searchManager.executeSearch()
                        } label: {
                            Text("All Exts")
                                .font(.system(size: 11, weight: searchManager.selectedExtension.isEmpty ? .semibold : .regular))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(searchManager.selectedExtension.isEmpty ? Color.secondary.opacity(0.15) : Color.secondary.opacity(0.06))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        ForEach(popularExtensions, id: \.self) { ext in
                            Button {
                                if searchManager.selectedExtension == ext {
                                    searchManager.selectedExtension = ""
                                } else {
                                    searchManager.selectedExtension = ext
                                }
                                searchManager.executeSearch()
                            } label: {
                                Text(".\(ext)")
                                    .font(.system(size: 11, weight: searchManager.selectedExtension == ext ? .semibold : .regular))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(searchManager.selectedExtension == ext ? Color.accentColor : Color.secondary.opacity(0.06))
                                    .foregroundStyle(searchManager.selectedExtension == ext ? Color.white : Color.primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                }

                Spacer()

                if !searchManager.query.isEmpty || searchManager.selectedCategory != .all || !searchManager.selectedExtension.isEmpty || searchManager.sizeFilter != .any || searchManager.dateFilter != .any {
                    Button("Reset") {
                        searchManager.clearAllFilters()
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .padding(.trailing, 4)
                }

                if !searchManager.results.isEmpty || !searchManager.query.isEmpty {
                    Text("\(searchManager.results.count) items (\(String(format: "%.1f", searchManager.searchDurationMs)) ms)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 6)
                }

                Button {
                    Task {
                        await searchManager.prewarmIndex()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Re-index cloud tree (\(searchManager.totalIndexedCount) files cached)")
                .padding(.trailing, 14)
            }
        }
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
    }

    // MARK: - 3. Results Content Area
    private var resultsContentArea: some View {
        Group {
            let hasActiveFilter = searchManager.selectedCategory != .all ||
                                  !searchManager.selectedExtension.isEmpty ||
                                  searchManager.sizeFilter != .any ||
                                  searchManager.dateFilter != .any

            if searchManager.query.isEmpty && !hasActiveFilter {
                emptySearchPrompt
            } else if searchManager.results.isEmpty {
                noResultsView
            } else {
                List(searchManager.results) { item in
                    searchResultRow(item)
                }
                .listStyle(.inset)
            }
        }
    }

    // Row item
    private func searchResultRow(_ item: SearchResultItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.iconName)
                .font(.title2)
                .foregroundStyle(categoryColor(item.category))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.body.weight(.semibold))

                    matchBadge(item.matchType)

                    Spacer()

                    Text(item.formattedSize)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Text(item.modifiedDate, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 6) {
                    Text("My Drive / \(item.relativePath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if !item.matchedReason.isEmpty {
                        Text("• \(item.matchedReason)")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }

            // Quick action buttons
            HStack(spacing: 6) {
                Button {
                    searchManager.revealInFinder(url: item.fullURL)
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    searchManager.openFile(url: item.fullURL)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open File")

                Button {
                    searchManager.copyPath(url: item.fullURL)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Copy Path")
            }
        }
        .padding(.vertical, 6)
    }

    private func matchBadge(_ type: SearchMatchType) -> some View {
        Text(type.rawValue)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(badgeColor(type).opacity(0.14))
            .foregroundStyle(badgeColor(type))
            .clipShape(Capsule())
    }

    private func badgeColor(_ type: SearchMatchType) -> Color {
        switch type {
        case .exact: return .green
        case .prefix: return .blue
        case .semantic: return .purple
        case .tag: return .orange
        }
    }

    private func categoryColor(_ cat: FileCategory) -> Color {
        switch cat {
        case .documents: return .blue
        case .media: return .purple
        case .images: return .pink
        case .code: return .green
        case .archives: return .orange
        case .folders: return .yellow
        case .all: return .secondary
        }
    }

    private var emptySearchPrompt: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 42))
                .foregroundStyle(Color.accentColor.opacity(0.8))

            Text("Global Search")
                .font(.title3.bold())

            Text("Search across everything in your ZeroDrive Cloud Vault instantly.\nFind files by keyword, type, extension, size, or date.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            VStack(alignment: .leading, spacing: 8) {
                Text("Try searching for:")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    suggestionChip("invoices")
                    suggestionChip("ext:mov")
                    suggestionChip("size:>100m")
                    suggestionChip("screen recordings")
                    suggestionChip("react components")
                }
            }
            .padding(.top, 8)

            Spacer()
        }
    }

    private func suggestionChip(_ text: String) -> some View {
        Button {
            searchManager.query = text
            searchManager.executeSearch()
        } label: {
            Text(text)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.08))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var noResultsView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text("No Files Found")
                .font(.headline)

            Text("No files matched your criteria.\nTry clearing filters or broadening your search terms.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button("Clear All Filters") {
                searchManager.clearAllFilters()
            }
            .controlSize(.small)
            .padding(.top, 4)

            Spacer()
        }
    }
}
