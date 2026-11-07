import SwiftUI
import UniformTypeIdentifiers

public struct FabricSpaceItem: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let url: URL
    public var fileCount: Int
    public var sizeBytes: Int64

    public var formattedSize: String {
        if sizeBytes == 0 {
            return fileCount == 0 ? "Empty" : "Zero KB"
        }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

public struct FabricDriveMigrationCard: View {
    @EnvironmentObject var supervisor: RcloneDaemonSupervisor
    @ObservedObject private var turbo = TurboMigrationManager.shared

    @State private var detectedSpaces: [FabricSpaceItem] = []

    // Selected Source (Defaults to Desktop/MAIN if present, otherwise Home)
    @State private var selectedItemURL: URL = {
        let desktopMain = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/MAIN")
        if FileManager.default.fileExists(atPath: desktopMain.path) {
            return desktopMain
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }()
    @State private var customDestinationSubfolder: String = ""
    @State private var pendingTransfer: PendingTransferItem? = nil
    @State private var sourceItemCount: Int = 0
    @State private var sourceSizeBytes: Int64 = 0
    @State private var isLocationADropTargeted: Bool = false

    public init() {}

    private var isSourceFromFabric: Bool {
        selectedItemURL.path.contains("FabricDrive")
    }

    private var selectedItemName: String {
        selectedItemURL.lastPathComponent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // MARK: - 1. Visual Left-to-Right Transfer Card
            VStack(alignment: .leading, spacing: 12) {
                // Header Row
                HStack(alignment: .center) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(turbo.telemetry.isRunning ? Color.green : (turbo.telemetry.isComplete ? Color.blue : Color.secondary))
                            .frame(width: 9, height: 9)
                        Text(turbo.telemetry.isRunning ? "Moving to Cloud Vault…" : "Move Folders to Cloud & Free Up Mac Space")
                            .font(.headline)
                    }

                    Spacer()

                    if turbo.telemetry.isRunning {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Verifying & Freeing Space")
                                .font(.caption.bold())
                                .foregroundStyle(Color.accentColor)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(.green)
                                .font(.caption2)
                            Text("Skips Duplicates • Verifies Before Deleting")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // 3-Column Pipeline: [From This Mac] ──► [Speed & Progress] ──► [To My Drive (Cloud)]
                HStack(alignment: .center, spacing: 12) {
                    // LEFT BOX: From This Mac (Click to Browse or Drop Folder/Files)
                    Button {
                        if !turbo.telemetry.isRunning {
                            openFinderFilePicker()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 5) {
                                Image(systemName: isSourceFromFabric ? "cloud.fill" : "laptopcomputer")
                                    .foregroundStyle(.blue)
                                Text("FROM THIS MAC")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if !turbo.telemetry.isRunning {
                                    Text("Click or Drop…")
                                        .font(.caption2.bold())
                                        .foregroundStyle(Color.accentColor)
                                }
                            }

                            if turbo.telemetry.isRunning {
                                Text(turbo.telemetry.sourceLocation.isEmpty ? turbo.telemetry.spaceName : turbo.telemetry.sourceLocation)
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text("\(ByteCountFormatter.string(fromByteCount: turbo.telemetry.remainingBytes, countStyle: .file)) left to move")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text("\(max(0, turbo.telemetry.totalFiles - turbo.telemetry.movedFiles)) files remaining")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            } else if !turbo.queuedSpaces.isEmpty {
                                HStack(spacing: 5) {
                                    Image(systemName: "square.stack.3d.up.fill")
                                        .font(.caption)
                                        .foregroundStyle(Color.accentColor)
                                    Text("\(turbo.queuedSpaces.count) Folders Ready")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                                Text("Total: \(totalQueuedSizeFormatted)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text("Click to choose different folders")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary.opacity(0.8))
                            } else {
                                HStack(spacing: 6) {
                                    Image(systemName: "folder.fill")
                                        .font(.caption)
                                        .foregroundStyle(Color.accentColor)
                                    Text(selectedItemName)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }

                                Text(ByteCountFormatter.string(fromByteCount: sourceSizeBytes, countStyle: .file) + (sourceItemCount > 0 ? " • \(sourceItemCount) files" : ""))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)

                                Text(truncatedBreadcrumb(selectedItemURL.path))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(selectedItemURL.path)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isLocationADropTargeted ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isLocationADropTargeted ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: 1.2)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(turbo.telemetry.isRunning)
                    .onDrop(of: [.fileURL], isTargeted: $isLocationADropTargeted) { providers in
                        handleDropOnLocationA(providers)
                        return true
                    }

                    // MIDDLE CONNECTOR: Transfer Speed, Direction Arrow & ETA
                    VStack(spacing: 4) {
                        if turbo.telemetry.isRunning {
                            if turbo.telemetry.speedMBps > 0.1 {
                                HStack(spacing: 4) {
                                    Image(systemName: "bolt.fill")
                                        .foregroundStyle(Color.orange)
                                        .font(.caption)
                                    Text(String(format: "%.1f MB/s", turbo.telemetry.speedMBps))
                                        .font(.headline.monospacedDigit())
                                        .foregroundStyle(Color.primary)
                                }
                                Text("Saving to Cloud")
                                    .font(.caption2.bold())
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .controlSize(.mini)
                                    Image(systemName: "icloud.and.arrow.down.fill")
                                        .foregroundStyle(Color.blue)
                                        .font(.caption)
                                    Text("Step 1 of 2")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(Color.blue)
                                }
                                Text("Fetching 1 file…")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 2) {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(height: 2)
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(Color.accentColor)
                            }

                            Text(turbo.telemetry.speedMBps > 0.1 ? formatETA(turbo.telemetry.etaSeconds) : "1-by-1 Safe Drain")
                                .font(.caption2.bold().monospacedDigit())
                                .foregroundStyle(Color.accentColor)
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.right.circle.fill")
                                    .foregroundStyle(Color.secondary)
                                    .font(.caption)
                                Text("Ready")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(Color.secondary)
                            }

                            HStack(spacing: 2) {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.3))
                                    .frame(height: 2)
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(Color.secondary.opacity(0.3))
                            }

                            Text("0 KB used on Mac")
                                .font(.caption2)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    .frame(width: 140)

                    // RIGHT BOX: To My Drive (Cloud Vault)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) {
                            Image(systemName: "icloud.fill")
                                .foregroundStyle(.green)
                            Text("TO MY DRIVE (CLOUD VAULT)")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 4) {
                            Image(systemName: "externaldrive.fill")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                            Text("My Drive")
                                .font(.caption.bold())
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.tertiary)
                            Text(turbo.telemetry.isRunning ? (turbo.telemetry.destLocation.replacingOccurrences(of: "My Drive/", with: "")) : (customDestinationSubfolder.isEmpty ? selectedItemName : customDestinationSubfolder))
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }

                        if turbo.telemetry.isRunning {
                            Text("Saved: \(ByteCountFormatter.string(fromByteCount: turbo.telemetry.movedBytes, countStyle: .file))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.green)
                            Text("\(turbo.telemetry.movedFiles) of \(turbo.telemetry.totalFiles) files safe")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Available in Finder on all your Macs")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("~/ZeroDrive/My Drive")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // High-visibility Progress Bar
                ProgressView(value: turbo.telemetry.isRunning ? min(1.0, max(0.0, turbo.telemetry.percent / 100.0)) : (turbo.telemetry.isComplete ? 1.0 : 0.0))
                    .progressViewStyle(.linear)

                // Sub-Bar: Live Status Message
                if turbo.telemetry.isRunning {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(turbo.telemetry.speedMBps > 0.1 ? Color.green : Color.blue)
                            .frame(width: 7, height: 7)
                        Text(turbo.telemetry.statusMessage.isEmpty ? "Moving files to Cloud Vault…" : turbo.telemetry.statusMessage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                } else if turbo.telemetry.isComplete && !turbo.telemetry.statusMessage.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text(turbo.telemetry.statusMessage)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Divider()
                    .padding(.vertical, 2)

                // Live Honest Storage Receipts (Zero Hardcoded Projections)
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SPACE FREED ON THIS MAC")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        if let ledger = turbo.ledger, ledger.totalFreedOnMacBytes > 0 {
                            Text("+\(ByteCountFormatter.string(fromByteCount: ledger.totalFreedOnMacBytes, countStyle: .file)) reclaimed by ZeroDrive")
                                .font(.caption.bold().monospacedDigit())
                                .foregroundStyle(.green)
                        } else {
                            Text("Drop any folder above or click Choose Folder to free up Mac space")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("MAC FREE SPACE RIGHT NOW")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(shutilCurrentFree()), countStyle: .file) + " available")
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(Color.green)
                    }

                    if turbo.telemetry.isRunning {
                        Button("Stop") {
                            turbo.cancel()
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .padding(.leading, 8)
                    }
                }
            }
            .padding(14)
            .background(turbo.telemetry.isRunning ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(turbo.telemetry.isRunning ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.12), lineWidth: 1)
            )

            // MARK: - 2. Clean Primary Action Bar
            HStack(spacing: 12) {
                Button {
                    openFinderFilePicker()
                } label: {
                    Label("Choose Folder or Files…", systemImage: "folder.badge.plus")
                }
                .controlSize(.regular)

                Spacer()

                if !turbo.queuedSpaces.isEmpty && !turbo.telemetry.isRunning {
                    Button {
                        turbo.runQueuedMoves()
                    } label: {
                        Text("Move All Queued (\(turbo.queuedSpaces.count))")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                } else {
                    Button {
                        startDirectMoveCurrentSource()
                    } label: {
                        Text(turbo.telemetry.isRunning ? "Add Another Folder…" : "Move \"\(selectedItemName)\" to Cloud…")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
            }
        }
        .sheet(item: $pendingTransfer) { pending in
            TransferConfirmationSheet(pendingItem: pending) { confirmed in
                pendingTransfer = nil
                TurboMigrationManager.shared.startTransfer(
                    urls: confirmed.urls,
                    destinationSubfolder: confirmed.destinationFolder,
                    isCopy: confirmed.isCopy,
                    leaveSymlink: confirmed.leaveSymlink
                )
            } onCancel: {
                pendingTransfer = nil
            }
        }
        .onAppear {
            scanFabricSpaces()
            updateSourceStats(selectedItemURL)
        }
    }

    private func truncatedBreadcrumb(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var clean = path
        if clean.hasPrefix(home) {
            clean = "~" + clean.dropFirst(home.count)
        }
        let parts = clean.split(separator: "/")
        if parts.count > 3 {
            return parts.prefix(2).joined(separator: "/") + "/…/" + parts.last!
        }
        return clean
    }

    private func openFinderFilePicker() {
        let panel = NSOpenPanel()
        panel.title = "Choose Folder or Files to Move to ZeroDrive"
        panel.prompt = "Review Move"
        panel.message = "Pick any folder or files on your Mac. You can also leave a shortcut (symlink) behind so apps and scripts still find your folder."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = selectedItemURL.deletingLastPathComponent()

        if panel.runModal() == .OK {
            let urls = panel.urls
            guard !urls.isEmpty else { return }
            selectedItemURL = urls[0]
            updateSourceStats(urls[0])
            pendingTransfer = PendingTransferItem(
                urls: urls,
                destinationFolder: customDestinationSubfolder.isEmpty ? urls[0].lastPathComponent : customDestinationSubfolder
            )
        }
    }

    private func handleDropOnLocationA(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var targetURL: URL? = nil
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    targetURL = url
                } else if let url = item as? URL {
                    targetURL = url
                }
                if let url = targetURL {
                    DispatchQueue.main.async {
                        self.selectedItemURL = url
                        self.updateSourceStats(url)
                        self.pendingTransfer = PendingTransferItem(
                            urls: [url],
                            destinationFolder: self.customDestinationSubfolder.isEmpty ? url.lastPathComponent : self.customDestinationSubfolder
                        )
                    }
                }
            }
        }
    }

    private func startDirectMoveCurrentSource() {
        if turbo.telemetry.isRunning {
            openFinderFilePicker()
        } else {
            pendingTransfer = PendingTransferItem(
                urls: [selectedItemURL],
                destinationFolder: customDestinationSubfolder.isEmpty ? selectedItemName : customDestinationSubfolder
            )
        }
    }

    private func updateSourceStats(_ url: URL) {
        if let found = detectedSpaces.first(where: { $0.url.path == url.path }) {
            self.sourceItemCount = found.fileCount
            self.sourceSizeBytes = found.sizeBytes
            return
        }

        DispatchQueue.global(qos: .utility).async {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }

            if !isDir.boolValue {
                let sz = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                DispatchQueue.main.async {
                    self.sourceItemCount = 1
                    self.sourceSizeBytes = sz
                }
                return
            }

            var count = 0
            var size: Int64 = 0
            if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                for case let fileURL as URL in enumerator {
                    if let res = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                       res.isRegularFile == true {
                        count += 1
                        size += Int64(res.fileSize ?? 0)
                        if count > 5000 { break }
                    }
                }
            }

            DispatchQueue.main.async {
                self.sourceItemCount = count
                self.sourceSizeBytes = size
            }
        }
    }

    private var totalQueuedSizeFormatted: String {
        let total = turbo.queuedSpaces.reduce(Int64(0)) { acc, name in
            acc + (detectedSpaces.first(where: { $0.name == name })?.sizeBytes ?? 0)
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private func formatETA(_ seconds: Int) -> String {
        if seconds <= 0 { return "Calculating…" }
        let mins = seconds / 60
        let secs = seconds % 60
        return mins > 0 ? "\(mins)m \(secs)s left" : "\(secs)s left"
    }

    private func shutilCurrentFree() -> UInt64 {
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? NSNumber {
            return free.uint64Value
        }
        return 0
    }

    private func scanFabricSpaces() {
        DispatchQueue.global(qos: .utility).async {
            let base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/CloudStorage/FabricDrive/Andrew Naegeles Workspace/Spaces")
            guard let items = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey]) else {
                return
            }

            var scanned: [FabricSpaceItem] = []
            for item in items {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                let name = item.lastPathComponent
                if name.hasPrefix(".") { continue }

                var count = 0
                var size: Int64 = 0
                if let enumerator = FileManager.default.enumerator(at: item, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                    for case let fileURL as URL in enumerator {
                        if let res = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                           res.isRegularFile == true {
                            count += 1
                            size += Int64(res.fileSize ?? 0)
                        }
                    }
                }

                scanned.append(FabricSpaceItem(
                    id: name,
                    name: name,
                    url: item,
                    fileCount: count,
                    sizeBytes: size
                ))
            }

            let sorted = scanned.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                self.detectedSpaces = sorted
            }
        }
    }
}
