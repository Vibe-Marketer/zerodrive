import SwiftUI

public struct MenuBarPopoverView: View {
    @EnvironmentObject var lifecycleController: AppLifecycleController
    @EnvironmentObject var supervisor: RcloneDaemonSupervisor
    @EnvironmentObject var spoolManager: SpoolAndGuardManager
    @EnvironmentObject var indexer: RAMTreeIndexer

    @State private var isDropTargeted: Bool = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(supervisor.isMounted ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 1) {
                    Text("ZeroDrive")
                        .font(.headline)
                    Text(supervisor.isMounted ? "Connected • 0 Local SSD Used" : "Connecting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Show in Finder") {
                    supervisor.openInFinder(supervisor.mountPoint.appendingPathComponent("My Drive"))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Divider()

            if spoolManager.dirtyFileCount > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Uploading \(spoolManager.dirtyFileCount) item(s)")
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
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Everything's up to date")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "arrow.up.doc")
                    .foregroundStyle(.secondary)
                Text("Drop files here to move to My Drive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isDropTargeted ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
                return true
            }

            Divider()

            HStack {
                Button("Open ZeroDrive") {
                    lifecycleController.setStudioWindowVisible(true)
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
        .frame(width: 280)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await withCheckedContinuation({ cont in
                    _ = provider.loadObject(ofClass: URL.self) { u, _ in cont.resume(returning: u) }
                }) {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                TurboMigrationManager.shared.startDirectMove(urls: urls)
            }
        }
    }
}
