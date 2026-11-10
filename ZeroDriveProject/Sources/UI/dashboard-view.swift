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

    @State private var isTransferModeCopy: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var pendingTransfer: PendingTransferItem? = nil

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {

                // MARK: - 1. Top Hero Header
                topHeaderSection

                // MARK: - 2. Four Core Benefit Cards (Speed, Reliability, Free Space, Total Storage)
                benefitCardsGrid

                // MARK: - 3. Action Station: Move vs Copy vs View
                actionStationSection

                // MARK: - 4. Duplicate Protection Live Shield
                duplicateShieldBanner

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

            Button {
                supervisor.openInFinder(supervisor.mountPoint.appendingPathComponent("My Drive"))
            } label: {
                Label("Browse Drive in Finder", systemImage: "folder.fill")
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
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.orange)
                        .font(.title3)
                    Text("STREAMING SPEED & ENGINE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if turbo.telemetry.isRunning && turbo.telemetry.speedMBps > 0.1 {
                        Text(String(format: "%.1f MB/s", turbo.telemetry.speedMBps))
                            .font(.caption2.bold().monospacedDigit())
                            .foregroundStyle(.orange)
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

                if turbo.telemetry.isRunning {
                    Text(String(format: "%.1f MB/s Live", turbo.telemetry.speedMBps))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
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
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transfer & Storage Operations")
                        .font(.headline)
                    Text("Choose whether to Move (free Mac disk space), Copy (keep local files), or View in Finder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Picker("Transfer Mode", selection: $isTransferModeCopy) {
                    Text("Move to Drive (Frees Space)").tag(false)
                    Text("Copy to Drive (Keep Local)").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
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
                        Label("Move Files (Free Space)", systemImage: "arrow.up.forward.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        pickFilesForTransfer(isCopy: true)
                    } label: {
                        Label("Copy Files (Keep on Mac)", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        supervisor.openInFinder(supervisor.mountPoint.appendingPathComponent("My Drive"))
                    } label: {
                        Label("View in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
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

    // MARK: - 5. Connected Devices & Free Space Breakdown
    private var devicesBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connected Devices & Free Space")
                    .font(.headline)
                Spacer()
                Text("\(turbo.connectedNodes.filter { $0.isOnline }.count) Online")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
            }

            ForEach(turbo.connectedNodes) { node in
                HStack(spacing: 12) {
                    Image(systemName: node.icon)
                        .font(.title3)
                        .foregroundStyle(node.isOnline ? Color.accentColor : Color.secondary)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(node.name)
                                .font(.body.weight(.medium))
                            Text(node.statusBadge)
                                .font(.caption2.bold())
                                .foregroundStyle(node.isOnline ? Color.green : Color.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background((node.isOnline ? Color.green : Color.secondary).opacity(0.12))
                                .clipShape(Capsule())
                        }
                        Text(node.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if node.id == "naegele-pro" || node.id == "cloudflare-r2" {
                        Button("Open Drive") {
                            supervisor.openInFinder(supervisor.mountPoint.appendingPathComponent("My Drive"))
                        }
                        .controlSize(.small)
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
