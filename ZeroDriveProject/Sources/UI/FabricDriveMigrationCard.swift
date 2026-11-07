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

    // Local Mac Selection State (100% independent of remote/cloud streams)
    @State private var selectedItemURLs: [URL] = []
    @State private var customDestinationSubfolder: String = ""
    @State private var leaveSymlinkOnMainCard: Bool = false
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
            return "\(selectedItemURLs.count) Folders/Items Selected"
        }
        return primarySelectedURL?.lastPathComponent ?? "Click or Drop Folder…"
    }

    private var existingVaultFolders: [String] {
        var set = Set<String>(vaultStats.folders.filter { $0 != "Google Drive" && !$0.hasPrefix(".") })
        let myDriveURL = supervisor.mountPoint.appendingPathComponent("My Drive")
        if let localDirs = try? FileManager.default.contentsOfDirectory(at: myDriveURL, includingPropertiesForKeys: [.isDirectoryKey]) {
            for d in localDirs {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: d.path, isDirectory: &isDir), isDir.boolValue {
                    let name = d.lastPathComponent
                    if !name.hasPrefix(".") && name != "Google Drive" {
                        set.insert(name)
                    }
                }
            }
        }
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var effectiveDestinationLabel: String {
        if turbo.isLocalTransferRunning {
            return turbo.localTelemetry.destLocation.replacingOccurrences(of: "My Drive/", with: "")
        }
        let clean = customDestinationSubfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !clean.isEmpty {
            if selectedItemURLs.count > 1 {
                return "\(clean)/<each-folder>"
            } else if let first = primarySelectedURL, clean != first.lastPathComponent {
                return "\(clean)/\(first.lastPathComponent)"
            }
            return clean
        }
        if selectedItemURLs.count > 1 {
            return "Top Level (<each-folder>)"
        }
        if let first = primarySelectedURL {
            return first.lastPathComponent
        }
        return "Top Level (My Drive)"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // =========================================================================
            // CARD 1: LOCAL MAC TRANSFER PICKER (ALWAYS AVAILABLE FOR THIS MAC!)
            // =========================================================================
            VStack(alignment: .leading, spacing: 12) {
                // Header Row
                HStack(alignment: .center) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(turbo.isLocalTransferRunning ? Color.green : Color.accentColor)
                            .frame(width: 9, height: 9)
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
                            Text("Verifies in R2 Before Deleting Local Copy")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // 3-Column Pipeline: [1. From This Mac (Source)] ──► [Arrow / Speed] ──► [2. To My Drive (Destination Picker)]
                HStack(alignment: .top, spacing: 12) {

                    // LEFT BOX: 1. FROM THIS MAC (SOURCE PICKER)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: isSourceFromFabric ? "cloud.fill" : "laptopcomputer")
                                .foregroundStyle(.blue)
                            Text("1. FROM THIS MAC (SOURCE)")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                            if hasSelection && !turbo.isLocalTransferRunning {
                                Button(role: .destructive) {
                                    clearCurrentSelection()
                                } label: {
                                    HStack(spacing: 2) {
                                        Image(systemName: "xmark.circle.fill")
                                        Text("Clear")
                                    }
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
                            Text("\(ByteCountFormatter.string(fromByteCount: turbo.localTelemetry.remainingBytes, countStyle: .file)) left to move")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text("\(max(0, turbo.localTelemetry.totalFiles - turbo.localTelemetry.movedFiles)) files remaining")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else if !selectedItemURLs.isEmpty, let firstURL = primarySelectedURL {
                            HStack(spacing: 6) {
                                Image(systemName: selectedItemURLs.count > 1 ? "square.stack.3d.up.fill" : "folder.fill")
                                    .font(.subheadline)
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

                            HStack(spacing: 8) {
                                Button {
                                    openFinderFilePicker(openSheetImmediately: false)
                                } label: {
                                    Label("Change Source…", systemImage: "folder")
                                        .font(.caption2.bold())
                                }
                                .controlSize(.small)
                                .buttonStyle(.bordered)

                                Button {
                                    reviewAndMoveCurrentSelection()
                                } label: {
                                    Label("Inspect List (\(selectedItemURLs.count))…", systemImage: "list.bullet")
                                        .font(.caption2.bold())
                                }
                                .controlSize(.small)
                                .buttonStyle(.borderless)
                            }
                            .padding(.top, 2)
                        } else {
                            Button {
                                openFinderFilePicker(openSheetImmediately: false)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "folder.badge.plus")
                                            .font(.title3)
                                            .foregroundStyle(Color.accentColor)
                                        Text("Select Folder or Drive…")
                                            .font(.headline)
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    Text("Click to browse this Mac or drag & drop folders here")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("Select 1 folder or 50+ folders at once")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
                    .background(isLocationADropTargeted ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isLocationADropTargeted ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: 1.2)
                    )
                    .onDrop(of: [.fileURL], isTargeted: $isLocationADropTargeted) { providers in
                        handleDropOnLocationA(providers)
                        return true
                    }

                    // MIDDLE CONNECTOR: Local Transfer Speed or Ready State
                    VStack(spacing: 4) {
                        Spacer(minLength: 16)
                        if turbo.isLocalTransferRunning {
                            if turbo.localTelemetry.speedMBps > 0.1 {
                                HStack(spacing: 4) {
                                    Image(systemName: "bolt.fill")
                                        .foregroundStyle(Color.orange)
                                        .font(.caption)
                                    Text(String(format: "%.1f MB/s", turbo.localTelemetry.speedMBps))
                                        .font(.headline.monospacedDigit())
                                        .foregroundStyle(Color.primary)
                                }
                                Text(String(format: "%.1f%% Done", turbo.localTelemetry.percent))
                                    .font(.caption2.bold().monospacedDigit())
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .controlSize(.mini)
                                    Text("Moving…")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(Color.blue)
                                }
                            }

                            HStack(spacing: 2) {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(height: 2)
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(Color.accentColor)
                            }

                            Text(formatETA(turbo.localTelemetry.etaSeconds))
                                .font(.caption2.bold().monospacedDigit())
                                .foregroundStyle(Color.accentColor)
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: leaveSymlinkOnMainCard ? "link.circle.fill" : "arrow.right.circle.fill")
                                    .foregroundStyle(hasSelection ? Color.accentColor : Color.secondary)
                                    .font(.caption)
                                Text(leaveSymlinkOnMainCard ? "Move + Link" : "Move to Cloud")
                                    .font(.caption.bold())
                                    .foregroundStyle(hasSelection ? Color.accentColor : Color.secondary)
                            }

                            HStack(spacing: 2) {
                                Rectangle()
                                    .fill(hasSelection ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.3))
                                    .frame(height: 2)
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(hasSelection ? Color.accentColor : Color.secondary.opacity(0.3))
                            }

                            Text("0 KB used on Mac")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 16)
                    }
                    .frame(width: 118)

                    // RIGHT BOX: 2. TO MY DRIVE (INTERACTIVE VAULT DESTINATION PICKER!)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: "icloud.fill")
                                .foregroundStyle(.green)
                            Text("2. TO MY DRIVE (VAULT FOLDER)")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                browseOrCreateFolderInMyDrive()
                            } label: {
                                Text("Browse…")
                                    .font(.caption2.bold())
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        }

                        HStack(spacing: 4) {
                            Image(systemName: "externaldrive.fill")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                            Text("My Drive")
                                .font(.caption.bold())
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.tertiary)
                            Text(effectiveDestinationLabel)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        if turbo.isLocalTransferRunning {
                            Text("Saved: \(ByteCountFormatter.string(fromByteCount: turbo.localTelemetry.movedBytes, countStyle: .file))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.green)
                            Text("\(turbo.localTelemetry.movedFiles) of \(turbo.localTelemetry.totalFiles) files safe")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else if isCreatingNewDestFolder {
                            HStack(spacing: 6) {
                                TextField("New folder name (e.g. _DEV)", text: $newDestFolderInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                                Button("Create") {
                                    let trimmed = newDestFolderInput.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                                    if !trimmed.isEmpty {
                                        let targetURL = supervisor.mountPoint.appendingPathComponent("My Drive").appendingPathComponent(trimmed)
                                        try? FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
                                        customDestinationSubfolder = trimmed
                                    }
                                    isCreatingNewDestFolder = false
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                Button("✕") {
                                    isCreatingNewDestFolder = false
                                }
                                .controlSize(.small)
                            }
                        } else {
                            // Direct Folder Picker Dropdown + "+ New Folder" right on the Main Card!
                            HStack(spacing: 6) {
                                Menu {
                                    Button("Top Level (My Drive)") {
                                        customDestinationSubfolder = ""
                                    }
                                    if let first = primarySelectedURL {
                                        let parent = first.deletingLastPathComponent().lastPathComponent
                                        let home = FileManager.default.homeDirectoryForCurrentUser.lastPathComponent
                                        if !parent.isEmpty && parent != home && parent != "/" {
                                            Button("Parent Folder (\(parent))") {
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
                                        Label("New Folder…", systemImage: "folder.badge.plus")
                                    }
                                } label: {
                                    Label(customDestinationSubfolder.isEmpty ? "Choose Vault Folder…" : "Folder: \(customDestinationSubfolder)", systemImage: "folder")
                                        .font(.caption2.bold())
                                }
                                .controlSize(.small)

                                Button {
                                    isCreatingNewDestFolder = true
                                    newDestFolderInput = ""
                                } label: {
                                    Label("New Folder", systemImage: "plus")
                                        .font(.caption2.bold())
                                }
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                            }
                            .padding(.top, 2)
                        }
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.15), lineWidth: 1.2)
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
                    .padding(.vertical, 2)

                // Direct Symlink Toggle + Action Buttons Row on Main View
                HStack(alignment: .center, spacing: 12) {
                    Toggle(isOn: $leaveSymlinkOnMainCard) {
                        HStack(spacing: 5) {
                            Image(systemName: "link")
                                .foregroundStyle(Color.accentColor)
                                .font(.caption)
                            Text("Leave shortcut (symlink) in old spot")
                                .font(.caption.weight(.medium))
                        }
                    }
                    .toggleStyle(.checkbox)
                    .help("Leaves a 0 KB link at the original Mac path so scripts, apps, and automations still find your moved folder(s).")

                    Spacer()

                    Button {
                        openFinderFilePicker(openSheetImmediately: false)
                    } label: {
                        Label(hasSelection ? "Select Different Folders…" : "1. Select Folders on Mac…", systemImage: "folder.badge.plus")
                    }
                    .controlSize(.regular)

                    if hasSelection {
                        Button(role: .destructive) {
                            clearCurrentSelection()
                        } label: {
                            Text("Clear")
                        }
                        .controlSize(.regular)
                    }

                    Button {
                        if hasSelection {
                            reviewAndMoveCurrentSelection()
                        } else {
                            openFinderFilePicker(openSheetImmediately: true)
                        }
                    } label: {
                        Text(hasSelection
                             ? (selectedItemURLs.count > 1
                                ? "Review & Move \(selectedItemURLs.count) Items…"
                                : "Review & Move \"\(selectedItemName)\"…")
                             : "2. Review & Move to Cloud…")
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
                customDestinationSubfolder = confirmed.destinationFolder
                leaveSymlinkOnMainCard = confirmed.leaveSymlink
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

    private func openFinderFilePicker(openSheetImmediately: Bool) {
        let panel = NSOpenPanel()
        panel.title = "Choose Folder or Files on This Mac to Move to ZeroDrive"
        panel.prompt = openSheetImmediately ? "Review Move" : "Select"
        panel.message = "Pick 1 or multiple folders or files on this Mac."
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
            // Auto-default parent folder name when multiple folders are selected and customDestinationSubfolder is empty
            if customDestinationSubfolder.isEmpty && urls.count > 1, let first = urls.first {
                let parent = first.deletingLastPathComponent().lastPathComponent
                let home = FileManager.default.homeDirectoryForCurrentUser.lastPathComponent
                if !parent.isEmpty && parent != home && parent != "/" {
                    customDestinationSubfolder = parent
                }
            }
            updateSourceStats(urls)
            if openSheetImmediately {
                pendingTransfer = PendingTransferItem(
                    urls: urls,
                    destinationFolder: customDestinationSubfolder,
                    isCopy: false,
                    leaveSymlink: leaveSymlinkOnMainCard
                )
            }
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
                    leaveSymlink: self.leaveSymlinkOnMainCard
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
            openFinderFilePicker(openSheetImmediately: true)
            return
        }
        pendingTransfer = PendingTransferItem(
            urls: selectedItemURLs,
            destinationFolder: customDestinationSubfolder,
            isCopy: false,
            leaveSymlink: leaveSymlinkOnMainCard
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
