import SwiftUI
import AppKit

public struct MenuBarPopoverView: View {
    @EnvironmentObject var lifecycleController: AppLifecycleController
    @EnvironmentObject var supervisor: RcloneDaemonSupervisor
    @EnvironmentObject var spoolManager: SpoolAndGuardManager
    @EnvironmentObject var indexer: RAMTreeIndexer
    @ObservedObject private var turbo = TurboMigrationManager.shared
    @ObservedObject private var vaultStats = VaultStats.shared
    @ObservedObject private var licensing = ManageLicensing.shared
    @ObservedObject private var updater = ManageAppUpdates.shared

    public init() {}

    public var body: some View {
        Group {
            if !licensing.isLicensed {
                signedOutPopoverBody
            } else {
                signedInPopoverBody
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var signedOutPopoverBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("ZeroDrive")
                        .font(.headline)
                    Text("Sign in required to mount My Drive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Button("Open ZeroDrive Setup…") {
                lifecycleController.openOnboarding(atStep: 0)
                lifecycleController.setStudioWindowVisible(true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .frame(maxWidth: .infinity)

            Divider()

            HStack {
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var signedInPopoverBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            // MARK: - 1. Top Connection Header
            HStack(spacing: 8) {
                Circle()
                    .fill(supervisor.isMounted ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)

                let upSpeed = max(turbo.telemetry.isRunning ? turbo.telemetry.speedMBps : 0, spoolManager.telemetry.uploadSpeedMBps)
                let downSpeed = spoolManager.telemetry.downloadSpeedMBps

                VStack(alignment: .leading, spacing: 1) {
                    Text("ZeroDrive")
                        .font(.headline)
                    if upSpeed > 0.05 || downSpeed > 0.05 {
                        Text("↑ \(String(format: "%.1f", upSpeed)) MB/s  ↓ \(String(format: "%.1f", downSpeed)) MB/s • Live")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.orange)
                    } else {
                        Text("\(turbo.connectedNodes.filter { $0.isOnline }.count) Connections Active • Finder Ready")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button("Open My Drive") {
                    supervisor.openInFinder(supervisor.mountPoint.appendingPathComponent("My Drive"))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            // MARK: - 2. Two-Metric Storage Pill (Cloud vs Mac Free Space)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("IN CLOUD VAULT")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(formattedCloudVaultSize)
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()
                    .frame(height: 24)
                    .padding(.horizontal, 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text("MAC FREE SPACE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: currentMacFreeBytes, countStyle: .file))
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(.green)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // MARK: - 3. Live Process & Activity Status (Local or Cloud/Mini Stream)
            if turbo.telemetry.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                        Text(turbo.telemetry.spaceName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                        if turbo.telemetry.speedMBps > 0.1 {
                            Text(String(format: "%.1f MB/s", turbo.telemetry.speedMBps))
                                .font(.caption.bold().monospacedDigit())
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    ProgressView(value: min(1.0, max(0.0, turbo.telemetry.percent / 100.0)))
                        .progressViewStyle(.linear)

                    HStack {
                        Text("\(ByteCountFormatter.string(fromByteCount: turbo.telemetry.movedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: turbo.telemetry.totalBytes, countStyle: .file)) • \(turbo.telemetry.movedFiles)/\(turbo.telemetry.totalFiles) files")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button("Stop") {
                            turbo.cancel()
                        }
                        .controlSize(.mini)
                        .buttonStyle(.bordered)
                    }
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if spoolManager.dirtyFileCount > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Saving \(spoolManager.dirtyFileCount) file(s) to Cloud…")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        if spoolManager.telemetry.uploadSpeedMBps > 0.05 {
                            Text(String(format: "%.1f MB/s", spoolManager.telemetry.uploadSpeedMBps))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("All files safe in Cloud • 0 KB used on Mac")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }

            // MARK: - 4. Compact Connected Devices & Clouds List
            VStack(alignment: .leading, spacing: 4) {
                Text("CONNECTED DEVICES & STREAMS")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)

                ForEach(turbo.connectedNodes.prefix(4)) { node in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(node.isOnline ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        Image(systemName: node.icon)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(node.name.components(separatedBy: " (").first ?? node.name)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text(node.statusBadge)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(node.statusBadge.contains("Streaming") || node.statusBadge.contains("Active") ? Color.accentColor : .secondary)
                    }
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // MARK: - 5. Primary Action Buttons (Move vs Copy)
            VStack(spacing: 6) {
                Button {
                    chooseFolderToMove()
                } label: {
                    HStack {
                        Image(systemName: "arrow.up.forward.circle.fill")
                            .foregroundStyle(Color.accentColor)
                        Text("Move to ZeroDrive (Free Mac Space)…")
                            .fontWeight(.medium)
                        Spacer()
                    }
                    .padding(.vertical, 3)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button {
                    chooseFolderToCopy()
                } label: {
                    HStack {
                        Image(systemName: "doc.badge.plus")
                            .foregroundStyle(Color.purple)
                        Text("Copy to ZeroDrive (Keep on Mac)…")
                            .fontWeight(.medium)
                        Spacer()
                    }
                    .padding(.vertical, 3)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            // MARK: - Duplicate Shield Indicator
            HStack(spacing: 6) {
                Image(systemName: "shield.checkerboard")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Text("Duplicate Shield Active • Zero duplicate waste")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)

            // MARK: - 5.5 Update Notice (When Available)
            if updater.updateAvailable, let latest = updater.latestRelease {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Update v\(latest.version) Available")
                            .font(.caption.bold())
                        Text("Signed release ready to install")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Install") {
                        lifecycleController.setStudioWindowVisible(true)
                        NSApp.activate(ignoringOtherApps: true)
                        updater.showUpdatePromptSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
                .padding(8)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            // MARK: - 6. Footer
            HStack {
                Button("Open Dashboard") {
                    lifecycleController.setStudioWindowVisible(true)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .controlSize(.small)

                Button("What's New") {
                    lifecycleController.setStudioWindowVisible(true)
                    NSApp.activate(ignoringOtherApps: true)
                    updater.openChangelog()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var formattedCloudVaultSize: String {
        if let bytes = vaultStats.liveTotalBytes, bytes > 0 {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        if let ledger = turbo.ledger, ledger.totalMovedToVaultBytes > 0 {
            return ByteCountFormatter.string(fromByteCount: ledger.totalMovedToVaultBytes, countStyle: .file)
        }
        return "Connected"
    }

    private var currentMacFreeBytes: Int64 {
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return 0
    }

    private func chooseFolderToMove() {
        lifecycleController.setStudioWindowVisible(true)
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Select Folder or Files to Move to ZeroDrive"
        panel.prompt = "Move & Free Space"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            TurboMigrationManager.shared.startDirectMove(urls: panel.urls)
        }
    }

    private func chooseFolderToCopy() {
        lifecycleController.setStudioWindowVisible(true)
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Select Folder or Files to Copy to ZeroDrive"
        panel.prompt = "Copy to Cloud"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            TurboMigrationManager.shared.startTransfer(
                urls: panel.urls,
                destinationSubfolder: "",
                isCopy: true,
                leaveSymlink: false,
                symlinkPaths: []
            )
        }
    }
}
