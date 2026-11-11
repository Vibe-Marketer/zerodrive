import SwiftUI
import AppKit

public struct StorageAdvisorView: View {
    @ObservedObject private var advisor = ManageStorageAdvisor.shared
    @EnvironmentObject var supervisor: RcloneDaemonSupervisor

    @State private var showConfirmReclaimSheet: Bool = false
    @State private var destinationFolder: String = "Cold Storage"

    public init() {}

    public var body: some View {
        Form {
            // MARK: - 1. Top Storage Reclaim Hero Card
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: "sparkles.rectangle.stack.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(Color.accentColor)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text("Storage Reclaim Advisor")
                                    .font(.title3.bold())
                                Text("SMART RECLAIM")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.16))
                                    .foregroundStyle(Color.accentColor)
                                    .clipShape(Capsule())
                            }

                            Text("Discovers cold, abandoned, and massive files on your Mac SSD and safely moves them to your 5 TB ZeroDrive Cloud Vault.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            advisor.startScan()
                        } label: {
                            Label(advisor.isScanning ? "Scanning Mac…" : "Scan Mac Now", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(advisor.isScanning || advisor.isReclaiming)
                    }

                    if advisor.isScanning {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: max(0.04, advisor.scanProgress))
                                .progressViewStyle(.linear)

                            Text(advisor.statusMessage)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(.top, 4)
                    } else if advisor.isReclaiming {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(advisor.statusMessage)
                                .font(.caption.bold())
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(.top, 4)
                    }

                    // Stat Pills Row
                    HStack(spacing: 12) {
                        statPill(
                            title: "RECLAIMABLE SPACE",
                            value: ByteCountFormatter.string(fromByteCount: advisor.totalReclaimableBytes, countStyle: .file),
                            subtitle: "\(advisor.items.count) files eligible",
                            color: advisor.totalReclaimableBytes > 0 ? Color.accentColor : .secondary
                        )

                        statPill(
                            title: "SELECTED TO OFFLOAD",
                            value: ByteCountFormatter.string(fromByteCount: advisor.selectedBytes, countStyle: .file),
                            subtitle: "\(advisor.selectedCount) files chosen",
                            color: advisor.selectedBytes > 0 ? .green : .secondary
                        )

                        statPill(
                            title: "LIFETIME RECLAIMED",
                            value: ByteCountFormatter.string(fromByteCount: advisor.totalSpaceReclaimedLifetime, countStyle: .file),
                            subtitle: "Saved to ZeroDrive",
                            color: .green
                        )
                    }
                    .padding(.top, 4)
                }
                .padding(.vertical, 4)
            }

            // MARK: - 2. Filter & Bulk Action Bar
            Section {
                HStack(spacing: 10) {
                    Picker("Category Filter", selection: $advisor.selectedFilter) {
                        ForEach(StorageAdvisorCategory.allCases) { cat in
                            Label(cat.rawValue, systemImage: cat.systemImage).tag(cat)
                        }
                    }
                    .pickerStyle(.segmented)

                    Spacer()

                    Button("Select All") {
                        advisor.selectAll(filterOnly: true)
                    }
                    .controlSize(.small)

                    Button("Deselect All") {
                        advisor.deselectAll()
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
            }

            // MARK: - 3. Recommendations List
            Section {
                if advisor.items.isEmpty && !advisor.isScanning {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.green)
                        Text("Your Mac is Clean & Optimized")
                            .font(.headline)
                        Text("No cold, abandoned, or oversized files found. Run a scan anytime to discover newly eligible items.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 380)

                        Button("Scan Mac Folders") {
                            advisor.startScan()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                } else {
                    let items = advisor.filteredItems

                    if items.isEmpty {
                        Text("No items found in '\(advisor.selectedFilter.rawValue)'")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    } else {
                        List {
                            ForEach(items) { item in
                                itemRow(item: item)
                            }
                        }
                        .frame(minHeight: 280, maxHeight: 420)
                    }
                }
            }

            // MARK: - 4. Bottom Reclaim Action
            if advisor.selectedBytes > 0 {
                Section {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ready to Reclaim Mac Space")
                                .font(.subheadline.bold())
                            Text("Files will be moved to ZeroDrive/My Drive/\(destinationFolder) and deleted from local SSD with 100% checksum verification.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            showConfirmReclaimSheet = true
                        } label: {
                            Label(
                                "Reclaim \(ByteCountFormatter.string(fromByteCount: advisor.selectedBytes, countStyle: .file)) Now",
                                systemImage: "arrow.up.circle.fill"
                            )
                            .padding(.horizontal, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(advisor.isReclaiming || advisor.isScanning)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Reclaim \(ByteCountFormatter.string(fromByteCount: advisor.selectedBytes, countStyle: .file)) of Mac SSD?",
            isPresented: $showConfirmReclaimSheet,
            titleVisibility: .visible
        ) {
            Button("Move to ZeroDrive & Free Space", role: .destructive) {
                Task {
                    await advisor.reclaimSelected(destinationSubfolder: destinationFolder)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will move \(advisor.selectedCount) items from your local Mac to ZeroDrive/My Drive/\(destinationFolder). Your local disk space will be freed immediately, and the files will remain accessible in Finder via ZeroDrive.")
        }
        .onAppear {
            if advisor.items.isEmpty && !advisor.isScanning {
                advisor.startScan()
            }
        }
    }

    private func itemRow(item: StorageAdvisorItem) -> some View {
        HStack(spacing: 12) {
            Button {
                advisor.toggleItemSelection(id: item.id)
            } label: {
                Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)

            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable()
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    Text(item.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)

                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("Opened \(item.formattedLastOpened)")
                        .font(.caption2)
                        .foregroundStyle(item.category == .cold ? Color.orange : Color.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(item.formattedSize)
                    .font(.subheadline.bold().monospacedDigit())

                Text(item.category.rawValue)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(badgeColor(for: item.category).opacity(0.14))
                    .foregroundStyle(badgeColor(for: item.category))
                    .clipShape(Capsule())
            }

            Button {
                NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
        }
        .padding(.vertical, 4)
    }

    private func badgeColor(for category: StorageAdvisorCategory) -> Color {
        switch category {
        case .all: return Color.accentColor
        case .cold: return Color.orange
        case .heavy: return Color.red
        case .installers: return Color.purple
        }
    }

    private func statPill(title: String, value: String, subtitle: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(color)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
