import SwiftUI
import AppKit
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
    @ObservedObject private var vaultStats = VaultStats.shared

    @State private var detectedSpaces: [FabricSpaceItem] = []

    // Local Mac Selection State (with per-folder symlink set)
    @State private var selectedItemURLs: [URL] = []
    @State private var selectedSymlinkPaths: Set<String> = []
    @State private var customDestinationSubfolder: String = ""
    @State private var isCreatingNewDestFolder: Bool = false
    @State private var newDestFolderInput: String = ""
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
            return "\(selectedItemURLs.count) Selected"
        }
        return primarySelectedURL?.lastPathComponent ?? "No Folder Selected"
    }

    private var existingVaultFolders: [String] {
        let set = Set<String>(vaultStats.folders.filter { $0 != "Google Drive" && !$0.hasPrefix(".") })
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var effectiveDestinationLabel: String {
        if turbo.isLocalTransferRunning {
            return turbo.localTelemetry.destLocation.replacingOccurrences(of: "My Drive/", with: "")
        }
        let clean = customDestinationSubfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !clean.isEmpty {
            return clean
        }
        if selectedItemURLs.count == 1, let first = primarySelectedURL {
            return first.lastPathComponent
        }
        return "Top Level (My Drive)"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // =========================================================================
            // CARD 1: LOCAL MAC TRANSFER PICKER (TIGHT, SYMMETRICAL LAYOUT)
            // =========================================================================
            VStack(alignment: .leading, spacing: 12) {
                // Header Row
                HStack(alignment: .center) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(turbo.isLocalTransferRunning ? Color.green : Color.accentColor)
                            .frame(width: 8, height: 8)
                        Text(turbo.isLocalTransferRunning ? "Moving from This Mac to Cloud Vault…" : "Move Folders from This Mac to Cloud Vault")
                            .font(.headline)
                    }

                    Spacer()

                    if turbo.isLocalTransferRunning {
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
                            Text("Verifies in ZeroDrive Before Deleting")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // 3-Column Pipeline: [1. FROM THIS MAC] ──► [Arrow] ──► [2. TO MY DRIVE]
                // NOTE: No unconstrained Spacers inside child VStacks so Form never stretches the height!
                HStack(alignment: .center, spacing: 10) {

                    // LEFT BOX: 1. FROM THIS MAC
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: isSourceFromFabric ? "cloud.fill" : "laptopcomputer")
                                .font(.caption)
                                .foregroundStyle(.blue)
                            Text("1. FROM THIS MAC")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                            if hasSelection && !turbo.isLocalTransferRunning {
                                Button {
                                    openFinderFilePicker()
                                } label: {
                                    Text("+ Add")
                                        .font(.caption2.bold())
                                        .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)

                                Text("•")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)

                                Button(role: .destructive) {
                                    clearCurrentSelection()
                                } label: {
                                    Text("Clear")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if turbo.isLocalTransferRunning {
                            Text(turbo.localTelemetry.sourceLocation.isEmpty ? turbo.localTelemetry.spaceName : turbo.localTelemetry.sourceLocation)
                                .font(.subheadline.bold())
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text("\(ByteCountFormatter.string(fromByteCount: turbo.localTelemetry.remainingBytes, countStyle: .file)) left • \(max(0, turbo.localTelemetry.totalFiles - turbo.localTelemetry.movedFiles)) files")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else if !selectedItemURLs.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: selectedItemURLs.count > 1 ? "square.stack.3d.up.fill" : "folder.fill")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                                Text("\(selectedItemURLs.count) Item\(selectedItemURLs.count == 1 ? "" : "s") (\(ByteCountFormatter.string(fromByteCount: sourceSizeBytes, countStyle: .file)))")
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                                Spacer()
                                Button("Edit List…") {
                                    reviewAndMoveCurrentSelection()
                                }
                                .buttonStyle(.borderless)
                                .font(.caption2.bold())
                                .foregroundStyle(Color.accentColor)
                            }

                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 3) {
                                    ForEach(selectedItemURLs, id: \.path) { url in
                                        let isDir = isURLDirectory(url)
                                        let isLinked = selectedSymlinkPaths.contains(url.path)
                                        HStack(spacing: 6) {
                                            Image(systemName: isDir ? "folder.fill" : "doc.fill")
                                                .font(.caption2)
                                                .foregroundStyle(Color.accentColor)
                                                .frame(width: 12)

                                            Text(url.lastPathComponent)
                                                .font(.caption.weight(.medium))
                                                .lineLimit(1)
                                                .truncationMode(.middle)

                                            Spacer()

                                            if isDir {
                                                Toggle(isOn: Binding(
                                                    get: { selectedSymlinkPaths.contains(url.path) },
                                                    set: { enabled in
                                                        if enabled {
                                                            selectedSymlinkPaths.insert(url.path)
                                                        } else {
                                                            selectedSymlinkPaths.remove(url.path)
                                                        }
                                                    }
                                                )) {
                                                    Text("Shortcut")
                                                        .font(.system(size: 10, weight: isLinked ? .bold : .regular))
                                                        .foregroundStyle(isLinked ? Color.accentColor : Color.secondary)
                                                }
                                                .toggleStyle(.checkbox)
                                                .controlSize(.mini)
                                            }

                                            Button {
                                                removeSingleURL(url)
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.primary.opacity(0.035))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                }
                            }
                            .frame(height: 62)
                        } else {
                            Button {
                                openFinderFilePicker()
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "folder.badge.plus")
                                            .font(.subheadline.bold())
                                            .foregroundStyle(Color.accentColor)
                                        Text("Click to Choose Folders or Files…")
                                            .font(.subheadline.bold())
                                            .foregroundStyle(Color.accentColor)
                                            .lineLimit(1)
                                    }
                                    Text("Or drag & drop 1 or multiple folders here")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isLocationADropTargeted ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isLocationADropTargeted ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: 1)
                    )
                    .onDrop(of: [.fileURL], isTargeted: $isLocationADropTargeted) { providers in
                        handleDropOnLocationA(providers)
                        return true
                    }

                    // MIDDLE CONNECTOR (Fixed Height, Zero Vertical Stretching!)
                    VStack(spacing: 3) {
                        if turbo.isLocalTransferRunning {
                            Text(String(format: "%.1f MB/s", turbo.localTelemetry.speedMBps))
                                .font(.caption.bold().monospacedDigit())
                                .foregroundStyle(Color.accentColor)
                        } else {
                            Text(!selectedSymlinkPaths.isEmpty ? "\(selectedSymlinkPaths.count) Linked" : "0 KB on Mac")
                                .font(.caption2.bold())
                                .foregroundStyle(hasSelection ? Color.accentColor : Color.secondary)
                        }

                        HStack(spacing: 2) {
                            Rectangle()
                                .fill(hasSelection || turbo.isLocalTransferRunning ? Color.accentColor : Color.secondary.opacity(0.35))
                                .frame(height: 2)
                            Image(systemName: "chevron.right")
                                .font(.caption2.bold())
                                .foregroundStyle(hasSelection || turbo.isLocalTransferRunning ? Color.accentColor : Color.secondary.opacity(0.35))
                        }
                    }
                    .frame(width: 82)

                    // RIGHT BOX: 2. TO MY DRIVE (CLEAN SINGLE-LINE HEADER + FULL-WIDTH DROPDOWN)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: "icloud.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                            Text("2. TO MY DRIVE")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                isCreatingNewDestFolder.toggle()
                                newDestFolderInput = ""
                            } label: {
                                Text("+ New Folder")
                                    .font(.caption2.bold())
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)

                            Text("•")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)

                            Button {
                                browseOrCreateFolderInMyDrive()
                            } label: {
                                Text("Browse…")
                                    .font(.caption2.bold())
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        }

                        if turbo.isLocalTransferRunning {
                            Text("My Drive ▸ \(effectiveDestinationLabel)")
                                .font(.subheadline.bold())
                                .lineLimit(1)
                            Text("Saved: \(ByteCountFormatter.string(fromByteCount: turbo.localTelemetry.movedBytes, countStyle: .file)) (\(turbo.localTelemetry.movedFiles)/\(turbo.localTelemetry.totalFiles) files)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.green)
                        } else if isCreatingNewDestFolder {
                            HStack(spacing: 6) {
                                TextField("Folder name in My Drive (e.g. _DEV)", text: $newDestFolderInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                                Button("Create") {
                                    let trimmed = newDestFolderInput.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                                    if !trimmed.isEmpty {
                                        vaultStats.addFolderLocally(trimmed)
                                        let targetURL = supervisor.mountPoint.appendingPathComponent("My Drive").appendingPathComponent(trimmed)
                                        DispatchQueue.global(qos: .userInitiated).async {
                                            try? FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
                                        }
                                        customDestinationSubfolder = trimmed
                                    }
                                    isCreatingNewDestFolder = false
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        } else {
                            // Full-width Folder Picker Menu (Never Truncates!)
                            Menu {
                                Button("Top Level (My Drive)") {
                                    customDestinationSubfolder = ""
                                }
                                if let first = primarySelectedURL {
                                    let parent = first.deletingLastPathComponent().lastPathComponent
                                    let home = FileManager.default.homeDirectoryForCurrentUser.lastPathComponent
                                    if !parent.isEmpty && parent != home && parent != "/" {
                                        Button("Same Parent Folder (\(parent))") {
                                            customDestinationSubfolder = parent
                                        }
                                    }
                                }
                                Divider()
                                Section("Existing Folders in My Drive") {
                                    ForEach(existingVaultFolders, id: \.self) { folder in
                                        Button {
                                            customDestinationSubfolder = folder
                                        } label: {
                                            Label(folder, systemImage: "folder")
                                        }
                                    }
                                }
                                Divider()
                                Button {
                                    isCreatingNewDestFolder = true
                                    newDestFolderInput = ""
                                } label: {
                                    Label("Create New Folder…", systemImage: "folder.badge.plus")
                                }
                                Button {
                                    browseOrCreateFolderInMyDrive()
                                } label: {
                                    Label("Browse My Drive in Finder…", systemImage: "folder")
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(Color.accentColor)
                                    Text("My Drive ▸ \(effectiveDestinationLabel)")
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                }
                            }
                            .controlSize(.regular)

                            Text("Click above to pick an existing folder or create a new one")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                    )
                }

                // Local Progress Bar (Only when a local transfer on THIS Mac is running)
                if turbo.isLocalTransferRunning {
                    ProgressView(value: min(1.0, max(0.0, turbo.localTelemetry.percent / 100.0)))
                        .progressViewStyle(.linear)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 7, height: 7)
                        Text(turbo.localTelemetry.statusMessage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Button("Stop Local Move") {
                            turbo.cancelLocalOnly()
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                }

                Divider()

                // Single Clean Footer Bar: Mac Free Space on Left, Primary Action Button on Right
                HStack(alignment: .center, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "internaldrive")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(shutilCurrentFree()), countStyle: .file)) free on this Mac")
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(.green)
                        if let ledger = turbo.ledger, ledger.totalFreedOnMacBytes > 0 {
                            Text("• +\(ByteCountFormatter.string(fromByteCount: ledger.totalFreedOnMacBytes, countStyle: .file)) reclaimed")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if hasSelection {
                        Button(role: .destructive) {
                            clearCurrentSelection()
                        } label: {
                            Text("Clear Selection")
                        }
                        .controlSize(.regular)
                    }

                    Button {
                        if hasSelection {
                            reviewAndMoveCurrentSelection()
                        } else {
                            openFinderFilePicker()
                        }
                    } label: {
                        Label(
                            hasSelection
                                ? (selectedItemURLs.count > 1
                                    ? "Review & Move \(selectedItemURLs.count) Selected Items…"
                                    : "Review & Move \"\(selectedItemName)\"…")
                                : "Select Folders or Files to Move…",
                            systemImage: hasSelection ? "arrow.up.right.circle.fill" : "folder.badge.plus"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
            }
            .padding(14)
            .background(turbo.isLocalTransferRunning ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(turbo.isLocalTransferRunning ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.12), lineWidth: 1)
            )

            // =========================================================================
            // CARD 2: SEPARATE LIVE REMOTE / CLOUD STREAM TELEMETRY (e.g. naegele-mm)
            // =========================================================================
            if let rem = turbo.remoteTelemetry, rem.isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center) {
                        HStack(spacing: 7) {
                            Image(systemName: "bolt.icloud.fill")
                                .foregroundStyle(Color.accentColor)
                            Text("Background Cloud Stream: \(rem.spaceName)")
                                .font(.subheadline.bold())
                            Text("Running on naegele-mm • 0 Mac Disk Used")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.14))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }

                        Spacer()

                        HStack(spacing: 6) {
                            Image(systemName: "bolt.fill")
                                .foregroundStyle(.orange)
                                .font(.caption2)
                            Text(String(format: "%.1f MB/s", rem.speedMBps))
                                .font(.subheadline.bold().monospacedDigit())
                                .foregroundStyle(.primary)
                            Text("•")
                                .foregroundStyle(.tertiary)
                            Text(String(format: "%.1f%%", rem.percent))
                                .font(.caption.bold().monospacedDigit())
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    ProgressView(value: min(1.0, max(0.0, rem.percent / 100.0)))
                        .progressViewStyle(.linear)

                    HStack {
                        Text("\(ByteCountFormatter.string(fromByteCount: rem.movedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: rem.totalBytes, countStyle: .file)) saved to \(rem.destLocation) • \(rem.movedFiles) / \(rem.totalFiles) files")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(formatETA(rem.etaSeconds))
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
                )
            }
        }
        .sheet(item: $pendingTransfer) { pending in
            TransferConfirmationSheet(pendingItem: pending) { confirmed in
                pendingTransfer = nil
                selectedItemURLs = confirmed.urls
                selectedSymlinkPaths = confirmed.symlinkPaths
                customDestinationSubfolder = confirmed.destinationFolder
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
        .onAppear {
            scanFabricSpaces()
        }
    }

    private func shutilCurrentFree() -> UInt64 {
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? NSNumber {
            return free.uint64Value
        }
        return 0
    }

    private func isURLDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func removeSingleURL(_ url: URL) {
        selectedItemURLs.removeAll { $0.path == url.path }
        selectedSymlinkPaths.remove(url.path)
        updateSourceStats(selectedItemURLs)
    }

    private func clearCurrentSelection() {
        selectedItemURLs.removeAll()
        selectedSymlinkPaths.removeAll()
        customDestinationSubfolder = ""
        sourceItemCount = 0
        sourceSizeBytes = 0
        turbo.clearQueue()
    }

    private func browseOrCreateFolderInMyDrive() {
        let myDriveURL = supervisor.mountPoint.appendingPathComponent("My Drive")
        let panel = NSOpenPanel()
        panel.title = "Choose or Create Destination Folder in My Drive"
        panel.prompt = "Select Destination"
        panel.message = "Select an existing folder inside My Drive, or click 'New Folder' to create one."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = myDriveURL

        if panel.runModal() == .OK, let chosenURL = panel.url {
            let rootPath = myDriveURL.path
            var rel = chosenURL.path
            if rel.hasPrefix(rootPath) {
                rel = String(rel.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            } else {
                rel = chosenURL.lastPathComponent
            }
            customDestinationSubfolder = rel
        }
    }

    private func openFinderFilePicker() {
        let panel = NSOpenPanel()
        panel.title = "Choose Folders or Files on This Mac to Move to ZeroDrive"
        panel.prompt = "Review & Configure Move"
        panel.message = "Select 1 or multiple folders or files. In the popup sheet next, you can toggle shortcuts (symlinks) per folder and pick the Vault destination."
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
            if customDestinationSubfolder.isEmpty && urls.count > 1, let first = urls.first {
                let parent = first.deletingLastPathComponent().lastPathComponent
                let home = FileManager.default.homeDirectoryForCurrentUser.lastPathComponent
                if !parent.isEmpty && parent != home && parent != "/" {
                    customDestinationSubfolder = parent
                }
            }
            updateSourceStats(urls)
            pendingTransfer = PendingTransferItem(
                urls: urls,
                destinationFolder: customDestinationSubfolder,
                isCopy: false,
                leaveSymlink: !selectedSymlinkPaths.isEmpty,
                symlinkPaths: selectedSymlinkPaths
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
                if self.customDestinationSubfolder.isEmpty && droppedURLs.count > 1, let first = droppedURLs.first {
                    let parent = first.deletingLastPathComponent().lastPathComponent
                    let home = FileManager.default.homeDirectoryForCurrentUser.lastPathComponent
                    if !parent.isEmpty && parent != home && parent != "/" {
                        self.customDestinationSubfolder = parent
                    }
                }
                self.updateSourceStats(droppedURLs)
                self.pendingTransfer = PendingTransferItem(
                    urls: droppedURLs,
                    destinationFolder: self.customDestinationSubfolder,
                    isCopy: false,
                    leaveSymlink: !self.selectedSymlinkPaths.isEmpty,
                    symlinkPaths: self.selectedSymlinkPaths
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
            destinationFolder: customDestinationSubfolder,
            isCopy: false,
            leaveSymlink: !selectedSymlinkPaths.isEmpty,
            symlinkPaths: selectedSymlinkPaths
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
