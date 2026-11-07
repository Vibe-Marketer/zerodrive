import SwiftUI
import AppKit

public struct MenuBarPopoverView: View {
    @EnvironmentObject var lifecycleController: AppLifecycleController
    @EnvironmentObject var supervisor: RcloneDaemonSupervisor
    @EnvironmentObject var spoolManager: SpoolAndGuardManager
    @EnvironmentObject var indexer: RAMTreeIndexer
    @ObservedObject private var turbo = TurboMigrationManager.shared
    @ObservedObject private var vaultStats = VaultStats.shared

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // MARK: - 1. Top Connection Header
            HStack(spacing: 8) {
                Circle()
                    .fill(supervisor.isMounted ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 1) {
                    Text("ZeroDrive")
                        .font(.headline)
                    Text(supervisor.isMounted ? "Connected in Finder" : "Connecting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

            // MARK: - 3. Live Process & Activity Status
            if turbo.telemetry.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                        Text("Moving \(turbo.telemetry.spaceName)")
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
                        Text(turbo.telemetry.statusMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
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

            // MARK: - 4. Primary Action Button (Replaces Broken Drop Box)
            Button {
                chooseFolderToMove()
            } label: {
                HStack {
                    Image(systemName: "folder.badge.plus")
                    Text("Move Folder or Files to Cloud…")
                        .fontWeight(.medium)
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Divider()

            // MARK: - 5. Footer
            HStack {
                Button("Open ZeroDrive Window") {
                    lifecycleController.setStudioWindowVisible(true)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .controlSize(.small)

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 295)
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
        panel.prompt = "Move to Cloud"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            TurboMigrationManager.shared.startDirectMove(urls: panel.urls)
        }
    }
}
