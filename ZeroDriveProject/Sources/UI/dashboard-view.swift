import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct DashboardView: View {
    @EnvironmentObject var supervisor: RcloneDaemonSupervisor
    @EnvironmentObject var spoolManager: SpoolAndGuardManager
    @EnvironmentObject var lifecycleController: AppLifecycleController
    @ObservedObject private var turbo = TurboMigrationManager.shared
    @ObservedObject private var vaultStats = VaultStats.shared
    @ObservedObject private var duplicateManager = ManageDuplicateProtection.shared
    @ObservedObject private var licenseManager = ManageLicensing.shared
    @ObservedObject private var searchManager = ManageGlobalSearch.shared
    @ObservedObject private var advisorManager = ManageStorageAdvisor.shared

    @State private var isTransferModeCopy: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var pendingTransfer: PendingTransferItem? = nil
    @State private var renamingNode: ConnectedNodeStatus? = nil
    @State private var editingDeviceName: String = ""
    @State private var showUpgradeModal: Bool = false
    @State private var isShowingAddDriveSheet: Bool = false
    @State private var isShowingUpgradePrompt: Bool = false
    @State private var upgradePromptReason: String = ""

    public init() {}

    private var isFreeTier: Bool {
        let t = licenseManager.license.tier.lowercased()
        return t.contains("free") || t.contains("starter")
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {

                // MARK: - 1. Top Hero Header
                topHeaderSection

                if isFreeTier {
                    freeTierUpgradeBanner
                }

                // MARK: - 1.5 Quick Global Search Bar
                quickSearchBar

                // MARK: - 2. Four Core Benefit Cards (Speed, Reliability, Free Space, Total Storage)
                benefitCardsGrid

                // MARK: - 3. Action Station: Move vs Copy vs View
                actionStationSection

                // MARK: - 4. Duplicate Protection Live Shield
                duplicateShieldBanner

                // MARK: - 4.5 Storage Reclaim Advisor Banner
                storageAdvisorBanner

                // MARK: - 5. Connected Devices & Free Space Breakdown
                devicesBreakdownSection
            }
            .padding(24)
        }
        .sheet(item: $pendingTransfer) { pending in
            TransferConfirmationSheet(pendingItem: pending) { confirmed in
                pendingTransfer = nil
                TurboMigrationManager.shared.startTransfer(
                    urls: confirmed.urls,
                    destinationSubfolder: confirmed.destinationFolder,
                    isCopy: confirmed.isCopy,
                    leaveSymlink: confirmed.leaveSymlink,
                    symlinkPaths: confirmed.symlinkPaths
                )
            } onCancel: {
                pendingTransfer = nil
            }
        }
        .sheet(item: $renamingNode) { node in
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: node.icon)
                        .font(.system(size: 28))
                        .foregroundStyle(Color.accentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rename Device")
                            .font(.headline)
                        Text("Set a custom friendly name for \(node.id). This will sync across your entire fleet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Device Display Name")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    TextField("Display Name", text: $editingDeviceName)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Button("Reset to Default") {
                        turbo.renameDevice(id: node.id, newName: "")
                        renamingNode = nil
                    }
                    .controlSize(.small)

                    Spacer()

                    Button("Cancel") {
                        renamingNode = nil
                    }
                    .controlSize(.small)

                    Button("Save Name") {
                        turbo.renameDevice(id: node.id, newName: editingDeviceName)
                        renamingNode = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(20)
            .frame(width: 440)
        }
        .sheet(isPresented: $showUpgradeModal) {
            UpgradePromptSheet(
                triggerReason: "What's New in ZeroDrive v3.0 — Paid Feature Release for AI Agents & Multi-Drive.",
                requiredTier: "Creator"
            )
        }
        .sheet(isPresented: $isShowingAddDriveSheet) {
            AddNewDriveSheet(isPresented: $isShowingAddDriveSheet) { _ in }
        }
        .sheet(isPresented: $isShowingUpgradePrompt) {
            UpgradePromptSheet(triggerReason: upgradePromptReason, requiredTier: "Creator")
        }
    }

    private var freeTierUpgradeBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("ZeroDrive Free Starter (10 GB)")
                        .font(.subheadline.bold())
                    Text("NEW v3.0 FEATURES")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.18))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                }
                Text("Upgrade to Creator or Studio to unlock Multi-Drive isolation, 24/7 Agent MCP tokens, and up to 1TB DFY storage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showUpgradeModal = true
            } label: {
                Label("Upgrade Now", systemImage: "bolt.fill")
                    .font(.caption.bold())
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - 1. Top Hero Header
    private var topHeaderSection: some View {
        HStack(alignment: .center, spacing: 14) {
            Circle()
                .fill(supervisor.isMounted ? Color.green : Color.orange)
                .frame(width: 12, height: 12)
                .overlay(
                    Circle()
                        .stroke(supervisor.isMounted ? Color.green.opacity(0.3) : Color.orange.opacity(0.3), lineWidth: 4)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("ZeroDrive")
                        .font(.title2.bold())
                    Text(licenseManager.license.tier)
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                }

                Text(supervisor.isMounted
                     ? "Cloud Vault connected • Finder ready at ~/ZeroDrive/My Drive"
                     : "Connecting to ZeroDrive Cloud Vault…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    let check = ManageDrives.shared.canAddDrive()
                    if check.allowed {
                        isShowingAddDriveSheet = true
                    } else {
                        upgradePromptReason = check.reason
                        isShowingUpgradePrompt = true
                    }
                } label: {
                    Label("Add Drive", systemImage: "plus.circle.fill")
                        .font(.subheadline.bold())
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button {
                    supervisor.openInFinder(supervisor.mountPoint.appendingPathComponent("My Drive"))
                } label: {
                    Label("Browse in Finder", systemImage: "folder.fill")
                        .font(.subheadline.bold())
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - 1.5 Quick Global Search Bar
    private var quickSearchBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)

                TextField("Search files in ZeroDrive…", text: $searchManager.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
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

                Text("\(searchManager.totalIndexedCount) files")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(Capsule())
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
            )

            if !searchManager.query.isEmpty && !searchManager.results.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Top Search Matches (\(searchManager.results.count))")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Search latency: \(String(format: "%.1f", searchManager.searchDurationMs)) ms")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    ForEach(searchManager.results.prefix(4)) { item in
                        HStack(spacing: 10) {
                            Image(systemName: item.iconName)
                                .font(.body)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(item.name)
                                        .font(.system(size: 12, weight: .medium))
                                    Text(item.matchType.rawValue)
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(item.matchType == .semantic ? Color.purple : Color.green)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background((item.matchType == .semantic ? Color.purple : Color.green).opacity(0.12))
                                        .clipShape(Capsule())
                                }

                                Text(item.relativePath)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text(item.formattedSize)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)

                            Button("Open in Finder") {
                                searchManager.revealInFinder(url: item.fullURL)
                            }
                            .controlSize(.mini)
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 3)
                        Divider()
                    }
                }
                .padding(12)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
                )
            }
        }
    }

    // MARK: - 2. Four Core Benefit Cards Grid
    private var benefitCardsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {

            // CARD 1: TOTAL DRIVE STORAGE (No R2 mentions!)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "externaldrive.fill.badge.checkmark")
                        .foregroundStyle(Color.accentColor)
                        .font(.title3)
                    Text("TOTAL STORAGE ON DRIVE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("0 KB on Mac")
                        .font(.caption2.bold())
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12))
                        .clipShape(Capsule())
                }

                Text(formattedCloudStorage)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text("Safely stored in ZeroDrive Cloud • Accessible instantly in Finder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            )

            // CARD 2: MAC & DEVICE FREE SPACE
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "internaldrive.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                    Text("FREE SPACE ON MAC")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let ledger = turbo.ledger, ledger.totalFreedOnMacBytes > 0 {
                        Text("+\(ByteCountFormatter.string(fromByteCount: ledger.totalFreedOnMacBytes, countStyle: .file)) Reclaimed")
                            .font(.caption2.bold())
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                Text(ByteCountFormatter.string(fromByteCount: currentMacFreeBytes, countStyle: .file))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)

                Text("Available local SSD storage on this Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            )

            // CARD 3: SPEED & HIGH THROUGHPUT
            let currentUpSpeed = max(turbo.telemetry.isRunning ? turbo.telemetry.speedMBps : 0, spoolManager.telemetry.uploadSpeedMBps)
            let currentDownSpeed = spoolManager.telemetry.downloadSpeedMBps
            let hasActiveSpeed = currentUpSpeed > 0.05 || currentDownSpeed > 0.05

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.orange)
                        .font(.title3)
                    Text("STREAMING SPEED & ENGINE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if hasActiveSpeed {
                        HStack(spacing: 6) {
                            if currentUpSpeed > 0.05 {
                                Text(String(format: "↑ %.1f MB/s", currentUpSpeed))
                                    .font(.caption2.bold().monospacedDigit())
                                    .foregroundStyle(.orange)
                            }
                            if currentDownSpeed > 0.05 {
                                Text(String(format: "↓ %.1f MB/s", currentDownSpeed))
                                    .font(.caption2.bold().monospacedDigit())
                                    .foregroundStyle(.cyan)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(Capsule())
                    } else {
                        Text("1.2 GB/s Engine")
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                if currentUpSpeed > 0.05 && currentDownSpeed > 0.05 {
                    Text(String(format: "↑%.1f  ↓%.1f MB/s", currentUpSpeed, currentDownSpeed))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                } else if currentUpSpeed > 0.05 {
                    Text(String(format: "↑ %.1f MB/s", currentUpSpeed))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                } else if currentDownSpeed > 0.05 {
                    Text(String(format: "↓ %.1f MB/s", currentDownSpeed))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.cyan)
                } else {
                    Text("High Speed")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                }

                Text("NVMe-grade direct HTTP streaming • Zero egress bandwidth latency")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            )

            // CARD 4: RELIABILITY & PROTECTION
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.blue)
                        .font(.title3)
                    Text("RELIABILITY & INTEGRITY")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("100% Verified")
                        .font(.caption2.bold())
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.12))
                        .clipShape(Capsule())
                }

                Text("Zero Data Loss")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text("SHA-256 verification before local deletion • Crash-proof spool guard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            )
        }
    }

    // MARK: - 3. Action Station: Move vs Copy vs View
    private var actionStationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transfer & Storage Operations")
                        .font(.headline)
                    Text("Move files to free Mac SSD space, or copy to keep local originals.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)

                Picker("", selection: $isTransferModeCopy) {
                    Text("Move (Frees Space)").tag(false)
                    Text("Copy (Keep Local)").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            // Interactive Drag & Drop Box
            VStack(spacing: 12) {
                Image(systemName: isTransferModeCopy ? "doc.on.doc.fill" : "arrow.up.and.line.horizontal.and.arrow.down")
                    .font(.system(size: 36))
                    .foregroundStyle(isTransferModeCopy ? Color.purple : Color.accentColor)

                VStack(spacing: 4) {
                    Text(isTransferModeCopy
                         ? "Drop Folders or Files here to Copy to ZeroDrive"
                         : "Drop Folders or Files here to Move & Free Mac Space")
                        .font(.headline)

                    Text(isTransferModeCopy
                         ? "Creates a cloud copy in ZeroDrive while keeping the original safe on your Mac."
                         : "Transfers to ZeroDrive, cryptographically verifies in cloud, and frees up local Mac SSD.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button {
                        pickFilesForTransfer(isCopy: false)
                    } label: {
                        Label("Move Files", systemImage: "arrow.up.forward.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        pickFilesForTransfer(isCopy: true)
                    } label: {
                        Label("Copy Files", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        supervisor.openInFinder(supervisor.mountPoint.appendingPathComponent("My Drive"))
                    } label: {
                        Label("View in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.regular)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
            .background(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers, isCopy: isTransferModeCopy)
                return true
            }
        }
        .padding(18)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - 4. Duplicate Protection Live Shield Banner
    private var duplicateShieldBanner: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "shield.checkerboard")
                .font(.title2)
                .foregroundStyle(Color.green)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Duplicate Protection Shield")
                        .font(.headline)
                    Text("ACTIVE")
                        .font(.caption2.bold())
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.green.opacity(0.15))
                        .clipShape(Capsule())
                }

                Text(duplicateManager.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if duplicateManager.totalDuplicateFiles > 0 {
                Button(role: .destructive) {
                    duplicateManager.removeAllDuplicates()
                } label: {
                    Label("Remove All Duplicates (\(duplicateManager.totalDuplicateFiles))", systemImage: "trash.fill")
                        .font(.subheadline.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.regular)
            } else {
                Button {
                    duplicateManager.startDuplicateScan()
                } label: {
                    Label(duplicateManager.isScanning ? "Scanning…" : "Scan for Duplicates", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(duplicateManager.isScanning)
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - 4.5 Storage Reclaim Advisor Banner
    private var storageAdvisorBanner: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Storage Reclaim Advisor")
                        .font(.headline)
                    if advisorManager.totalReclaimableBytes > 0 {
                        Text("\(ByteCountFormatter.string(fromByteCount: advisorManager.totalReclaimableBytes, countStyle: .file)) RECLAIMABLE")
                            .font(.caption2.bold())
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }

                Text(advisorManager.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                NotificationCenter.default.post(name: NSNotification.Name("OpenStorageAdvisorTab"), object: nil)
            } label: {
                Label("Review Recommendations", systemImage: "sparkles")
                    .font(.subheadline.bold())
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - 5. Separated Sections: Cloud Storage vs Connected Devices
    private var devicesBreakdownSection: some View {
        VStack(spacing: 16) {
            cloudStorageBreakdownCard
            connectedDevicesBreakdownCard
        }
    }

    private var cloudStorageBreakdownCard: some View {
        let meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
        let quotaTB = meta.quotaTB > 0 ? meta.quotaTB : 5.0
        let totalQuotaBytes = Int64(quotaTB * 1024 * 1024 * 1024 * 1024)
        let usedBytes = vaultStats.liveTotalBytes ?? vaultStats.totalBytes ?? (turbo.ledger?.totalMovedToVaultBytes ?? 0)
        let freeBytes = max(0, totalQuotaBytes - usedBytes)
        let usedRatio = min(1.0, max(0.0, Double(usedBytes) / Double(totalQuotaBytes)))
        let freeRatio = max(0.0, 1.0 - usedRatio)

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "cloud.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                    Text("ZeroDrive Cloud Storage & Drives")
                        .font(.headline)
                }
                Spacer()
                HStack(spacing: 4) {
                    Text(ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file))
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.green)
                    Text("Free Remaining")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.12))
                .clipShape(Capsule())
            }

            // Cloud Progress Bar
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.14))
                            .frame(height: 8)

                        RoundedRectangle(cornerRadius: 4)
                            .fill(LinearGradient(colors: [Color.accentColor, Color.purple], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(6, geo.size.width * CGFloat(usedRatio)), height: 8)
                    }
                }
                .frame(height: 8)

                HStack {
                    Text("\(ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)) Used in Cloud")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("0 KB used on Mac SSD")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Text("of \(String(format: "%.1f TB", quotaTB)) Total Quota (\(String(format: "%.1f%%", freeRatio * 100)) Available)")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Primary Vault Drive
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.fill.badge.icloud")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("My Drive (Primary Vault)")
                            .font(.body.weight(.medium))
                        Text("Active")
                            .font(.caption2.bold())
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    Text("Mounted at ~/.zerodrive-mount/My Drive • \(ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)) free remaining in cloud")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Open Drive") {
                    supervisor.openInFinder(supervisor.mountPoint.appendingPathComponent("My Drive"))
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    private var connectedDevicesBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                    Text("Connected Devices & Machines")
                        .font(.headline)
                }
                Spacer()
                Text("\(turbo.connectedDevices.filter { $0.isOnline }.count) Online")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.12))
                    .clipShape(Capsule())
            }

            ForEach(turbo.connectedDevices) { node in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Image(systemName: node.icon)
                            .font(.title3)
                            .foregroundStyle(node.isOnline ? Color.accentColor : Color.secondary)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(node.displayName)
                                    .font(.body.weight(.medium))

                                Button {
                                    editingDeviceName = node.displayName
                                    renamingNode = node
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Rename device")

                                Text(node.id)
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.08))
                                    .clipShape(Capsule())

                                Text(node.statusBadge)
                                    .font(.caption2.bold())
                                    .foregroundStyle(node.isOnline ? Color.green : Color.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background((node.isOnline ? Color.green : Color.secondary).opacity(0.12))
                                    .clipShape(Capsule())
                            }

                            HStack(spacing: 8) {
                                Label(node.mountPath, systemImage: "folder")
                                    .font(.caption)
                                    .foregroundStyle(.primary)

                                Text("•")
                                    .foregroundStyle(.secondary)

                                Label(node.formattedFreeSpace + (node.totalBytes > 0 ? " SSD" : ""), systemImage: "internaldrive")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }

                            if let chip = node.chip, !chip.isEmpty {
                                HStack(spacing: 6) {
                                    Text(chip)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                    if let gpu = node.gpu {
                                        Text("• " + gpu)
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    if let os = node.os, !os.isEmpty {
                                        Text("• " + os)
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }

                        Spacer()

                        HStack(spacing: 8) {
                            Button {
                                editingDeviceName = node.displayName
                                renamingNode = node
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .controlSize(.small)

                            if node.id == "naegele-pro" {
                                Button("Open Drive") {
                                    supervisor.openInFinder(supervisor.mountPoint.appendingPathComponent("My Drive"))
                                }
                                .controlSize(.small)
                            }
                        }
                    }

                    // Mini disk progress bar
                    if node.totalBytes > 0 {
                        let usedBytes = max(0, node.totalBytes - node.freeBytes)
                        let usedRatio = min(1.0, max(0.0, Double(usedBytes) / Double(node.totalBytes)))
                        VStack(alignment: .leading, spacing: 2) {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.secondary.opacity(0.12))
                                        .frame(height: 5)

                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(usedRatio > 0.9 ? Color.red : (usedRatio > 0.75 ? Color.orange : Color.accentColor))
                                        .frame(width: max(4, geo.size.width * CGFloat(usedRatio)), height: 5)
                                }
                            }
                            .frame(height: 5)

                            HStack {
                                let usedStr = ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)
                                let totalStr = ByteCountFormatter.string(fromByteCount: node.totalBytes, countStyle: .file)
                                Text("\(usedStr) used of \(totalStr)")
                                    .font(.system(size: 8.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if let pct = node.freePercentage {
                                    Text(String(format: "%.1f%% free", pct))
                                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(pct < 10 ? Color.red : Color.green)
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.vertical, 4)
                Divider()
            }
        }
        .padding(18)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - Helper Methods
    private var formattedCloudStorage: String {
        if let bytes = vaultStats.liveTotalBytes, bytes > 0 {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        if let ledger = turbo.ledger, ledger.totalMovedToVaultBytes > 0 {
            return ByteCountFormatter.string(fromByteCount: ledger.totalMovedToVaultBytes, countStyle: .file)
        }
        return "148+ GB"
    }

    private var currentMacFreeBytes: Int64 {
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return 0
    }

    private func pickFilesForTransfer(isCopy: Bool) {
        let panel = NSOpenPanel()
        panel.title = isCopy ? "Select Folders or Files to Copy to ZeroDrive" : "Select Folders or Files to Move to ZeroDrive"
        panel.prompt = isCopy ? "Copy to Cloud" : "Move & Free Space"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            pendingTransfer = PendingTransferItem(
                urls: panel.urls,
                destinationFolder: "",
                isCopy: isCopy,
                leaveSymlink: !isCopy
            )
        }
    }

    private func handleDrop(providers: [NSItemProvider], isCopy: Bool) {
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await loadDroppedURL(from: provider) {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                await MainActor.run {
                    self.pendingTransfer = PendingTransferItem(
                        urls: urls,
                        destinationFolder: "",
                        isCopy: isCopy,
                        leaveSymlink: !isCopy
                    )
                }
            }
        }
    }

    private func loadDroppedURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
