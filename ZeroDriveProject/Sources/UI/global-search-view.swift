import SwiftUI
import AppKit

public struct GlobalSearchView: View {
    @ObservedObject private var searchManager = ManageGlobalSearch.shared
    @EnvironmentObject var supervisor: RcloneDaemonSupervisor

    @State private var hoveredItemId: String? = nil

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
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)

                TextField("Search files across ZeroDrive…", text: $searchManager.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
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

                Picker("Mode", selection: $searchManager.searchMode) {
                    ForEach(SearchMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 290)
                .onChange(of: searchManager.searchMode) { _ in
                    searchManager.executeSearch()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
        }
        .padding(16)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 2. Filter Pills & Stats Row
    private var filterAndStatsBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(FileCategory.allCases) { cat in
                        Button {
                            searchManager.selectedCategory = cat
                            searchManager.executeSearch()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: cat.icon)
                                    .font(.caption2)
                                Text(cat.rawValue)
                                    .font(.caption.weight(searchManager.selectedCategory == cat ? .bold : .regular))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(searchManager.selectedCategory == cat ? Color.accentColor : Color.secondary.opacity(0.08))
                            .foregroundStyle(searchManager.selectedCategory == cat ? Color.white : Color.primary)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }

            Spacer()

            if !searchManager.query.isEmpty {
                Text("\(searchManager.results.count) results (\(String(format: "%.1f", searchManager.searchDurationMs)) ms)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
            }

            Button {
                Task {
                    await searchManager.prewarmIndex()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Re-index cloud tree (\(searchManager.totalIndexedCount) files cached)")
            .padding(.trailing, 16)
        }
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
    }

    // MARK: - 3. Results Content Area
    private var resultsContentArea: some View {
        Group {
            if searchManager.query.isEmpty {
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

            Text("Search across everything in your ZeroDrive Cloud Vault instantly.\nFind files by keyword, topic, extension, or exact name.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            VStack(alignment: .leading, spacing: 8) {
                Text("Try searching for:")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    suggestionChip("invoices")
                    suggestionChip("screen recordings")
                    suggestionChip("taxes")
                    suggestionChip(".mov")
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

            Text("No files matched \"\(searchManager.query)\" in \(searchManager.selectedCategory.rawValue).\nTry broadening your query or selecting another category.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button("Clear Filters") {
                searchManager.selectedCategory = .all
                searchManager.searchMode = .hybrid
                searchManager.executeSearch()
            }
            .controlSize(.small)
            .padding(.top, 4)

            Spacer()
        }
    }
}
