import SwiftUI

public struct SessionMoveEvent: Identifiable, Codable, Sendable {
    public let id: String
    public let filename: String
    public let spaceOrFolder: String
    public let sizeBytes: Int64
    public let timestamp: Date
    public let status: String // "Completed", "Moving", "Timed out"
    
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
    @State private var sessionStartTime = Date()

    public init() {}

    public var body: some View {
        Form {
            // Live Transfer Banner (if active)
            if turbo.telemetry.isRunning {
                Section("Live Transfer") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Active: \(turbo.telemetry.spaceName)")
                                .font(.headline)
                            Spacer()
                            Text(String(format: "%.1f MB/s", turbo.telemetry.speedMBps))
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(Color.accentColor)
                        }

                        ProgressView(value: turbo.telemetry.percent / 100.0)
                            .progressViewStyle(.linear)

                        HStack {
                            Text("\(turbo.telemetry.movedFiles) of \(turbo.telemetry.totalFiles) files moved (\(ByteCountFormatter.string(fromByteCount: turbo.telemetry.movedBytes, countStyle: .file)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if turbo.telemetry.etaSeconds > 0 {
                                Text("ETA: \(turbo.telemetry.etaSeconds / 60)m \(turbo.telemetry.etaSeconds % 60)s")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            // Session History Section
            Section("Current Session Activity") {
                if sessionEvents.isEmpty && !turbo.telemetry.isRunning {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("No files moved in this session yet.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("Files moved via ZeroDrive or Turbo Import will log here with exact timestamps and sizes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.vertical, 20)
                        Spacer()
                    }
                } else {
                    HStack {
                        Text("Session Total: \(sessionEvents.count) items moved (\(ByteCountFormatter.string(fromByteCount: totalSessionBytes, countStyle: .file)))")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear Session Log") {
                            sessionEvents.removeAll()
                            clearDiskLog()
                        }
                        .controlSize(.mini)
                    }

                    ForEach(sessionEvents.reversed()) { event in
                        HStack(spacing: 10) {
                            Image(systemName: event.status == "Completed" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(event.status == "Completed" ? Color.green : Color.orange)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.filename)
                                    .font(.body)
                                    .lineLimit(1)
                                Text("\(event.spaceOrFolder) • \(ByteCountFormatter.string(fromByteCount: event.sizeBytes, countStyle: .file))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(event.timestamp, style: .time)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Activity")
        .onAppear {
            loadSessionLog()
        }
    }

    private var totalSessionBytes: Int64 {
        sessionEvents.reduce(Int64(0)) { $0 + $1.sizeBytes }
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

    private func clearDiskLog() {
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/rclone/session-activity.json")
        try? FileManager.default.removeItem(at: logURL)
    }
}
