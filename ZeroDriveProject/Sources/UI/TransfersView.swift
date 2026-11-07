import SwiftUI
import AppKit

public struct SessionMoveEvent: Identifiable, Codable, Sendable {
    public let id: String
    public let filename: String
    public let spaceOrFolder: String
    public let sizeBytes: Int64
    public let timestamp: Date
    public let status: String

    public init(
        id: String = UUID().uuidString,
        filename: String,
        spaceOrFolder: String,
        sizeBytes: Int64,
        timestamp: Date = Date(),
        status: String = "Completed"
    ) {
        self.id = id
        self.filename = filename
        self.spaceOrFolder = spaceOrFolder
        self.sizeBytes = sizeBytes
        self.timestamp = timestamp
        self.status = status
    }
}

public struct TransfersView: View {
    @EnvironmentObject var spoolManager: SpoolAndGuardManager
    @EnvironmentObject var supervisor: RcloneDaemonSupervisor
    @ObservedObject private var turbo = TurboMigrationManager.shared

    @State private var sessionEvents: [SessionMoveEvent] = []

    public init() {}

    public var body: some View {
        Form {
            // MARK: - 1. Live Transfer Banner (if active)
            if turbo.telemetry.isRunning {
                Section("Moving Right Now") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Moving \(turbo.telemetry.spaceName)")
                                .font(.headline)
                            Spacer()
                            Text(String(format: "%.1f MB/s", turbo.telemetry.speedMBps))
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(Color.accentColor)
                        }

                        ProgressView(value: min(1.0, max(0.0, turbo.telemetry.percent / 100.0)))
                            .progressViewStyle(.linear)

                        HStack {
                            Text("\(turbo.telemetry.movedFiles) of \(turbo.telemetry.totalFiles) files saved (\(ByteCountFormatter.string(fromByteCount: turbo.telemetry.movedBytes, countStyle: .file)))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            if turbo.telemetry.etaSeconds > 0 {
                                Text("Time left: \(turbo.telemetry.etaSeconds / 60)m \(turbo.telemetry.etaSeconds % 60)s")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            // MARK: - 2. Active Folder Shortcuts (Symlinks)
            if !turbo.symlinks.isEmpty {
                Section("Folder Shortcuts on This Mac (Symlinks)") {
                    ForEach(turbo.symlinks) { link in
                        HStack(spacing: 10) {
                            Image(systemName: "link.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(link.folderName)
                                    .font(.body.weight(.medium))
                                Text("\(link.originalPath) → My Drive/\(link.folderName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            if link.bytesSaved > 0 {
                                Text("+\(ByteCountFormatter.string(fromByteCount: link.bytesSaved, countStyle: .file)) freed")
                                    .font(.caption.bold().monospacedDigit())
                                    .foregroundStyle(.green)
                            }

                            Button("Show in Finder") {
                                NSWorkspace.shared.selectFile(link.originalPath, inFileViewerRootedAtPath: (link.originalPath as NSString).deletingLastPathComponent)
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            // MARK: - 3. Completed Folder Transfers (From Migration Ledger)
            Section("Completed Moves & Space Freed") {
                if let ledger = turbo.ledger, !ledger.completedSpaces.isEmpty {
                    HStack {
                        Text("Total Mac Space Freed: +\(ByteCountFormatter.string(fromByteCount: ledger.totalFreedOnMacBytes, countStyle: .file))")
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(.green)
                        Spacer()
                        Text("\(ledger.completedSpaces.count) folders verified in Cloud Vault")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(ledger.completedSpaces) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.spaceName)
                                    .font(.body.weight(.medium))
                                Text("\(entry.filesMoved) files • \(ByteCountFormatter.string(fromByteCount: entry.bytesMoved, countStyle: .file)) • \(entry.status)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button("Open in Cloud") {
                                let target = supervisor.mountPoint.appendingPathComponent("My Drive").appendingPathComponent(entry.spaceName)
                                supervisor.openInFinder(target)
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    }
                } else if sessionEvents.isEmpty && !turbo.telemetry.isRunning {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.icloud")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("No transfers recorded yet.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("When you move folders to ZeroDrive, your completed transfers and freed Mac space will appear here.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.vertical, 20)
                        Spacer()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Activity")
        .onAppear {
            turbo.readLedger()
            turbo.readSymlinks()
            loadSessionLog()
        }
    }

    private func loadSessionLog() {
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/rclone/session-activity.json")
        guard let data = try? Data(contentsOf: logURL),
              let list = try? JSONDecoder().decode([SessionMoveEvent].self, from: data) else {
            return
        }
        self.sessionEvents = list
    }
}
