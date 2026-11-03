import SwiftUI
import Charts

public struct MenuBarPopoverView: View {
    @EnvironmentObject var lifecycleController: AppLifecycleController
    @EnvironmentObject var supervisor: RcloneDaemonSupervisor
    @EnvironmentObject var spoolManager: SpoolAndGuardManager
    @EnvironmentObject var indexer: RAMTreeIndexer

    @State private var streamGuard: Bool = false
    @State private var searchText: String = ""

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: supervisor.isMounted ? "externaldrive.fill.badge.checkmark" : "externaldrive.fill")
                    .foregroundStyle(supervisor.isMounted ? .green : .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ZeroDrive").font(.headline)
                    Text(spoolManager.telemetry.isOnline ? supervisor.statusMessage : "Offline — Local Spool Only")
                        .font(.caption2)
                        .foregroundStyle(spoolManager.telemetry.isOnline ? Color.secondary : Color.orange)
                }
                Spacer()
                Text(String(format: "%.1f MB/s", spoolManager.telemetry.uploadSpeedMBps))
                    .font(.caption)
                    .monospacedDigit()
                    .bold()
            }

            // 60-Second Rolling Area Chart (SwiftCharts)
            Chart(spoolManager.bandwidthHistory) { sample in
                AreaMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("MB/s", sample.speedMBps)
                )
                .foregroundStyle(.blue.opacity(0.25))

                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("MB/s", sample.speedMBps)
                )
                .foregroundStyle(.blue)
            }
            .chartXAxis(.hidden)
            .frame(height: 54)

            HStack {
                Text("Queue: \(spoolManager.telemetry.activeUploads) up • \(spoolManager.telemetry.activeQueued) queued")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Spool: \(ByteCountFormatter.string(fromByteCount: spoolManager.telemetry.spoolUsedBytes, countStyle: .file))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Stream / Call Guard (3 MB/s Cap)
            Toggle("Stream / Call Guard (3 MB/s Cap)", isOn: $streamGuard)
                .font(.caption)
                .onChange(of: streamGuard) { active in
                    spoolManager.telemetry.streamGuardActive = active
                    Task {
                        _ = await RcloneRCClient.shared.setBandwidthCap(rate: active ? "3M:off" : "off")
                    }
                }

            // Instant <1ms Search
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("Instant Cloud Search (<1 ms)...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
            }
            .padding(6)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(6)

            if !searchText.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(indexer.search(query: searchText).prefix(5)) { node in
                        HStack {
                            Image(systemName: node.isFolder ? "folder.fill" : "doc.fill")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                            Text(node.name).font(.caption).lineLimit(1)
                            Spacer()
                            Button("Reveal") {
                                indexer.revealInFinder(node: node)
                            }
                            .buttonStyle(.borderless)
                            .font(.caption2)
                            Button("Open") {
                                indexer.openFile(node: node)
                            }
                            .buttonStyle(.borderless)
                            .font(.caption2)
                        }
                    }
                }
                .padding(6)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(6)
            }

            // Mini Staging Drawer
            if spoolManager.dirtyFileCount > 0 {
                Divider()
                Text("Staging Spool (\(spoolManager.dirtyFileCount) unsynced)")
                    .font(.caption2)
                    .bold()
                ForEach(spoolManager.spoolItems.prefix(2)) { item in
                    HStack {
                        Text(item.filename).font(.caption2).lineLimit(1)
                        Spacer()
                        Button("Sync") { Task { await spoolManager.syncNow(item: item) } }
                            .buttonStyle(.borderless)
                            .font(.caption2)
                        Button("Purge") { Task { await spoolManager.purgeLocally(item: item) } }
                            .buttonStyle(.borderless)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }

            Divider()

            // Actions
            HStack {
                Button("Open Studio") {
                    lifecycleController.setStudioWindowVisible(true)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Finder") {
                    NSWorkspace.shared.open(supervisor.mountPoint)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                if supervisor.isMounted {
                    Button("Unmount") {
                        lifecycleController.requestSafeUnmount()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(.red)
                } else {
                    Button("Mount") {
                        Task { await supervisor.mountUnifiedDrive() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}
