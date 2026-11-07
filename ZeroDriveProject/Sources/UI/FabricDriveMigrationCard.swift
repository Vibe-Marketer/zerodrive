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

    // Selected Sources (Supports 1 or multiple folders/files, and can be cleared)
    @State private var selectedItemURLs: [URL] = []
    @State private var customDestinationSubfolder: String = ""
    @State private var pendingTransfer: PendingTransferItem? = nil
    @State private var sourceItemCount: Int = 0
    @State private var sourceSizeBytes: Int64 = 0
    @State private var isLocationADropTargeted: Bool = false

    public init() {}

    private var primarySelectedURL: URL? {
        selectedItemURLs.first
    }

    private var hasSelection: Bool {
        !selectedItemURLs.isEmpty || !turbo.queuedSpaces.isEmpty
    }

    private var isSourceFromFabric: Bool {
        primarySelectedURL?.path.contains("FabricDrive") == true
    }

    private var selectedItemName: String {
        if selectedItemURLs.count > 1 {
            return "\(selectedItemURLs.count) Items Selected"
        }
        return primarySelectedURL?.lastPathComponent ?? "No Folder Selected"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // MARK: - 1. Visual Left-to-Right Transfer Card (Shows Live Local OR Remote Stream Telemetry)
            VStack(alignment: .leading, spacing: 12) {
                // Header Row
                HStack(alignment: .center) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(turbo.telemetry.isRunning ? Color.green : (turbo.telemetry.isComplete ? Color.blue : Color.secondary))
                            .frame(width: 9, height: 9)
                        Text(turbo.telemetry.isRunning
                             ? (turbo.isRemoteStreamActive ? "Live Cloud Stream Running on naegele-mm…" : "Moving to Cloud Vault…")
                             : "Move Folders to Cloud & Free Up Mac Space")
                            .font(.headline)
                    }

                    Spacer()

                    if turbo.telemetry.isRunning {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(turbo.isRemoteStreamActive ? "Streaming Live (0 Disk Used)" : "Verifying & Freeing Space")
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

                // 3-Column Pipeline: [From This Mac / Source] ──► [Speed & Progress] ──► [To My Drive (Cloud)]
                HStack(alignment: .center, spacing: 12) {
                    // LEFT BOX: From This Mac (Click to Browse or Drop Folder/Files)
                    Button {
                        if !turbo.isLocalTransferRunning {
                            openFinderFilePicker()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 5) {
                                Image(systemName: turbo.telemetry.isRunning && turbo.isRemoteStreamActive ? "icloud.and.arrow.up.fill" : (isSourceFromFabric ? "cloud.fill" : "laptopcomputer"))
                                    .foregroundStyle(.blue)
                                Text(turbo.telemetry.isRunning && turbo.isRemoteStreamActive ? "LIVE REMOTE STREAM" : "FROM THIS MAC")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if !turbo.isLocalTransferRunning {
                                    Text("Click or Drop…")
                                        .font(.caption2.bold())
                                        .foregroundStyle(Color.accentColor)
                                }
                            }

                            if turbo.telemetry.isRunning && (turbo.isLocalTransferRunning || selectedItemURLs.isEmpty) {
                                Text(turbo.telemetry.sourceLocation.isEmpty ? turbo.telemetry.spaceName : turbo.telemetry.sourceLocation)
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text("\(ByteCountFormatter.string(fromByteCount: turbo.telemetry.remainingBytes, countStyle: .file)) left to move")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text("\(max(0, turbo.telemetry.totalFiles - turbo.telemetry.movedFiles)) of \(turbo.telemetry.totalFiles) files remaining")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            } else if !turbo.queuedSpaces.isEmpty {
                                HStack(spacing: 5) {
                                    Image(systemName: "square.stack.3d.up.fill")
                                        .font(.caption)
                                        .foregroundStyle(Color.accentColor)
                                    Text("\(turbo.queuedSpaces.count) Folders Queued")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                                Text(turbo.queuedSpaces.prefix(3).joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text("Click to review or change selection")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary.opacity(0.8))
                            } else if !selectedItemURLs.isEmpty, let firstURL = primarySelectedURL {
                                HStack(spacing: 6) {
                                    Image(systemName: selectedItemURLs.count > 1 ? "square.stack.3d.up.fill" : "folder.fill")
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

                                Text(truncatedBreadcrumb(selectedItemURLs.count > 1 ? firstURL.deletingLastPathComponent().path : firstURL.path))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(firstURL.path)
                            } else {
                                HStack(spacing: 6) {
                                    Image(systemName: "folder.badge.plus")
                                        .font(.subheadline)
                                        .foregroundStyle(Color.accentColor)
                                    Text("Choose or Drop Folders…")
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                }
                                Text("Pick 1 or multiple folders to move to My Drive")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Optionally leaves a 0 KB shortcut (symlink) behind")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
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
                    .disabled(turbo.isLocalTransferRunning)
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
                                Text(String(format: "%.1f%% Done", turbo.telemetry.percent))
                                    .font(.caption2.bold().monospacedDigit())
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .controlSize(.mini)
                                    Image(systemName: "icloud.and.arrow.down.fill")
                                        .foregroundStyle(Color.blue)
                                        .font(.caption)
                                    Text("Streaming")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(Color.blue)
                                }
                                Text("Verifying…")
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

                            Text(turbo.telemetry.speedMBps > 0.1 ? formatETA(turbo.telemetry.etaSeconds) : "0 KB Disk Used")
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
                            Text(turbo.telemetry.isRunning
                                 ? (turbo.telemetry.destLocation.replacingOccurrences(of: "My Drive/", with: ""))
                                 : (customDestinationSubfolder.isEmpty ? (selectedItemURLs.isEmpty ? "Choose Destination…" : selectedItemName) : customDestinationSubfolder))
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }

                        if turbo.telemetry.isRunning {
                            Text("Saved: \(ByteCountFormatter.string(fromByteCount: turbo.telemetry.movedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: turbo.telemetry.totalBytes, countStyle: .file))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.green)
                            Text("\(turbo.telemetry.movedFiles) of \(turbo.telemetry.totalFiles) files safe in R2")
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

                // Sub-Bar: Live Status Message + Current File
                if turbo.telemetry.isRunning {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(turbo.telemetry.speedMBps > 0.1 ? Color.green : Color.blue)
                            .frame(width: 7, height: 7)
                        Text(turbo.telemetry.statusMessage.isEmpty ? "Moving files to Cloud Vault…" : turbo.telemetry.statusMessage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        if !turbo.telemetry.currentFile.isEmpty {
                            Text(turbo.telemetry.currentFile)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
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

                    if turbo.isLocalTransferRunning {
                        Button("Stop Local Move") {
                            turbo.cancelLocalOnly()
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

            // MARK: - 2. Clean Primary Action Bar (With Clear Selection Button!)
            HStack(spacing: 10) {
                Button {
                    openFinderFilePicker()
                } label: {
                    Label("Choose Folder or Files…", systemImage: "folder.badge.plus")
                }
                .controlSize(.regular)

                if hasSelection {
                    Button(role: .destructive) {
                        clearCurrentSelection()
                    } label: {
                        Label("Clear Selection", systemImage: "xmark.circle")
                    }
                    .controlSize(.regular)
                    .help("Clear selected folders and reset queue")
                }

                Spacer()

                if !turbo.queuedSpaces.isEmpty && !turbo.isLocalTransferRunning {
                    Button {
                        turbo.runQueuedMoves()
                    } label: {
                        Text("Move All Queued (\(turbo.queuedSpaces.count))")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                } else if !selectedItemURLs.isEmpty {
                    Button {
                        reviewAndMoveCurrentSelection()
                    } label: {
                        Text(selectedItemURLs.count > 1
                             ? "Review & Move \(selectedItemURLs.count) Items to Cloud…"
                             : "Review & Move \"\(selectedItemName)\" to Cloud…")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                } else {
                    Button {
                        openFinderFilePicker()
                    } label: {
                        Text("Select Folders to Move to Cloud…")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
            }
        }
        .sheet(item: $pendingTransfer) { pending in
            TransferConfirmationSheet(pendingItem: pending) { confirmed in
                pendingTransfer = nil
                selectedItemURLs = confirmed.urls
                customDestinationSubfolder = confirmed.destinationFolder
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
        }
    }

    private func clearCurrentSelection() {
        selectedItemURLs.removeAll()
        customDestinationSubfolder = ""
        sourceItemCount = 0
        sourceSizeBytes = 0
        turbo.clearQueue()
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
        panel.message = "Pick 1 or multiple folders or files on your Mac. In the next step you can pick the destination folder in My Drive and optionally leave a shortcut (symlink) behind."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if let first = primarySelectedURL {
            panel.directoryURL = first.deletingLastPathComponent()
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        }

        if panel.runModal() == .OK {
            let urls = panel.urls
            guard !urls.isEmpty else { return }
            selectedItemURLs = urls
            updateSourceStats(urls)
            pendingTransfer = PendingTransferItem(
                urls: urls,
                destinationFolder: customDestinationSubfolder
            )
        }
    }

    private func handleDropOnLocationA(_ providers: [NSItemProvider]) {
        Task {
            var droppedURLs: [URL] = []
            for provider in providers {
                if let url = await loadDroppedURL(from: provider) {
                    droppedURLs.append(url)
                }
            }
            guard !droppedURLs.isEmpty else { return }
            await MainActor.run {
                self.selectedItemURLs = droppedURLs
                self.updateSourceStats(droppedURLs)
                self.pendingTransfer = PendingTransferItem(
                    urls: droppedURLs,
                    destinationFolder: self.customDestinationSubfolder
                )
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

    private func reviewAndMoveCurrentSelection() {
        guard !selectedItemURLs.isEmpty else {
            openFinderFilePicker()
            return
        }
        pendingTransfer = PendingTransferItem(
            urls: selectedItemURLs,
            destinationFolder: customDestinationSubfolder
        )
    }

    private func updateSourceStats(_ urls: [URL]) {
        let skipDirs: Set<String> = ["node_modules", ".next", "__pycache__", ".venv", "venv", ".git", "Pods", "build", ".build"]
        DispatchQueue.global(qos: .utility).async {
            var count = 0
            var size: Int64 = 0

            for url in urls {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }

                if !isDir.boolValue {
                    let sz = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                    count += 1
                    size += sz
                } else if let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) {
                    while let fileURL = enumerator.nextObject() as? URL {
                        if skipDirs.contains(fileURL.lastPathComponent) {
                            enumerator.skipDescendants()
                            continue
                        }
                        if let res = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                           res.isRegularFile == true {
                            count += 1
                            size += Int64(res.fileSize ?? 0)
                            if count > 20000 { break }
                        }
                    }
                }
            }

            let finalCount = count
            let finalSize = size
            DispatchQueue.main.async {
                self.sourceItemCount = finalCount
                self.sourceSizeBytes = finalSize
            }
        }
    }

    private func formatETA(_ seconds: Int) -> String {
        if seconds <= 0 { return "Calculating…" }
        let hrs = seconds / 3600
        let mins = (seconds % 3600) / 60
        let secs = seconds % 60
        if hrs > 0 {
            return "\(hrs)h \(mins)m left"
        }
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
