import SwiftUI
import AppKit

public struct DuplicateProtectionView: View {
    @ObservedObject private var manager = ManageDuplicateProtection.shared
    @EnvironmentObject var supervisor: RcloneDaemonSupervisor

    @State private var showConfirmRemoveAllSheet: Bool = false
    @State private var selectedGroupForDetails: DuplicateGroup? = nil

    public init() {}

    public var body: some View {
        Form {
            // MARK: - 1. Top Shield Overview Card
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: "shield.checkerboard")
                            .font(.system(size: 32))
                            .foregroundStyle(Color.green)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text("Duplicate Protection Shield")
                                    .font(.title3.bold())
                                Text("ACTIVE")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.16))
                                    .foregroundStyle(.green)
                                    .clipShape(Capsule())
                            }

                            Text("Cryptographic content matching protects your Cloud Vault from redundant files and wasted storage.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            manager.startDuplicateScan()
                        } label: {
                            Label(manager.isScanning ? "Scanning…" : "Scan ZeroDrive Now", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(manager.isScanning || manager.isCleaning)
                    }

                    if manager.isScanning {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: max(0.02, manager.scanProgress))
                                .progressViewStyle(.linear)

                            Text(manager.statusMessage)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(.top, 4)
                    } else if manager.isCleaning {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(manager.statusMessage)
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Stat Pills Row
                    HStack(spacing: 12) {
                        statPill(
                            title: "DUPLICATES DETECTED",
                            value: "\(manager.totalDuplicateFiles) files",
                            subtitle: manager.totalDuplicateFiles > 0 ? "\(manager.duplicateGroups.count) groups" : "0 groups",
                            color: manager.totalDuplicateFiles > 0 ? .red : .secondary
                        )

                        statPill(
                            title: "WASTED CLOUD STORAGE",
                            value: ByteCountFormatter.string(fromByteCount: manager.totalWastedBytes, countStyle: .file),
                            subtitle: "Reclaimable in 1 click",
                            color: manager.totalWastedBytes > 0 ? .red : .secondary
                        )

                        statPill(
                            title: "TOTAL SPACE RECLAIMED",
                            value: ByteCountFormatter.string(fromByteCount: manager.totalSpaceReclaimed, countStyle: .file),
                            subtitle: "Saved by Duplicate Shield",
                            color: .green
                        )
                    }
                    .padding(.top, 4)
                }
                .padding(.vertical, 4)
            }

            // MARK: - 2. Bulk 1-Click Clean Action (When Duplicates Exist)
            if manager.totalDuplicateFiles > 0 {
                Section("Bulk Action") {
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ready to Reclaim \(ByteCountFormatter.string(fromByteCount: manager.totalWastedBytes, countStyle: .file))")
                                .font(.headline)
                            Text("Clicking below will delete all \(manager.totalDuplicateFiles) redundant duplicate copies while leaving 1 verified original file intact.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button(role: .destructive) {
                            showConfirmRemoveAllSheet = true
                        } label: {
                            Label("Remove All Duplicates at Once", systemImage: "trash.fill")
                                .font(.subheadline.bold())
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.large)
                        .disabled(manager.isCleaning)
                    }
                    .padding(.vertical, 6)
                }
            }

            // MARK: - 3. Detected Duplicate Groups List
            Section("Duplicate Files (\(manager.duplicateGroups.count) Groups)") {
                if manager.duplicateGroups.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.title)
                                .foregroundStyle(.green)
                            Text("No Duplicates Found")
                                .font(.headline)
                            Text("Your ZeroDrive Cloud Vault is completely optimized. Zero wasted space.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 24)
                        Spacer()
                    }
                } else {
                    ForEach(manager.duplicateGroups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "doc.fill")
                                    .foregroundStyle(Color.accentColor)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.fileName)
                                        .font(.body.weight(.medium))
                                    Text("\(ByteCountFormatter.string(fromByteCount: group.fileSize, countStyle: .file)) each • \(group.duplicates.count) redundant copies (\(group.formattedWastedBytes) wasted)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button("Remove Duplicates") {
                                    manager.removeDuplicates(in: group)
                                }
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                                .tint(.red)
                            }

                            // Files in this group
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.caption2)
                                    Text("KEEP: \(group.original.path)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                ForEach(group.duplicates) { dup in
                                    HStack(spacing: 6) {
                                        Image(systemName: "trash")
                                            .foregroundStyle(.red)
                                            .font(.caption2)
                                        Text("DELETE: \(dup.path)")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                            .padding(8)
                            .background(Color.secondary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            // MARK: - 4. Shield Options
            Section("Protection Settings") {
                Toggle(isOn: $manager.autoPreventDuplicatesOnTransfer) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pre-Transfer Duplicate Shield")
                            .font(.body.weight(.medium))
                        Text("Automatically checks file hashes before uploading or moving to prevent creating duplicates in ZeroDrive.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Duplicate Protection")
        .confirmationDialog(
            "Remove All Duplicates?",
            isPresented: $showConfirmRemoveAllSheet,
            titleVisibility: .visible
        ) {
            Button("Remove All \(manager.totalDuplicateFiles) Duplicates", role: .destructive) {
                manager.removeAllDuplicates()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove \(manager.totalDuplicateFiles) duplicate file copies and reclaim \(ByteCountFormatter.string(fromByteCount: manager.totalWastedBytes, countStyle: .file)) of cloud space. The original copy of each file is kept intact.")
        }
    }

    private func statPill(title: String, value: String, subtitle: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.bold())
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
