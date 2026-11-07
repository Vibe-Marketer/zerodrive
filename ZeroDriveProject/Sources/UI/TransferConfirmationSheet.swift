import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct PendingTransferItem: Identifiable {
    public let id = UUID()
    public var urls: [URL]
    public var destinationFolder: String
    public var isCopy: Bool = false
    public var leaveSymlink: Bool = false

    public init(
        urls: [URL],
        destinationFolder: String = "",
        isCopy: Bool = false,
        leaveSymlink: Bool = false
    ) {
        self.urls = urls
        if !destinationFolder.isEmpty {
            self.destinationFolder = destinationFolder
        } else if urls.count > 1, let first = urls.first {
            // For multiple items (e.g. 54 folders inside ~/_DEV), default destination to their parent folder name (e.g. "_DEV")
            let parentName = first.deletingLastPathComponent().lastPathComponent
            let homeName = FileManager.default.homeDirectoryForCurrentUser.lastPathComponent
            if !parentName.isEmpty && parentName != homeName && parentName != "/" {
                self.destinationFolder = parentName
            } else {
                self.destinationFolder = ""
            }
        } else if let first = urls.first {
            self.destinationFolder = first.lastPathComponent
        } else {
            self.destinationFolder = ""
        }
        self.isCopy = isCopy
        self.leaveSymlink = leaveSymlink
    }
}

public struct TransferConfirmationSheet: View {
    let pendingItem: PendingTransferItem
    let onConfirm: (PendingTransferItem) -> Void
    let onCancel: () -> Void

    @ObservedObject private var vaultStats = VaultStats.shared

    @State private var selectedURLs: [URL] = []
    @State private var destinationFolder: String = ""
    @State private var isCopy: Bool = false
    @State private var leaveSymlink: Bool = false
    @State private var isCalculating: Bool = true
    @State private var totalSizeBytes: Int64 = 0
    @State private var totalItemCount: Int = 0
    @State private var showAllSelectedItems: Bool = true
    @State private var isCreatingNewFolder: Bool = false
    @State private var newFolderNameInput: String = ""

    public init(
        pendingItem: PendingTransferItem,
        onConfirm: @escaping (PendingTransferItem) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.pendingItem = pendingItem
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _selectedURLs = State(initialValue: pendingItem.urls)
        _destinationFolder = State(initialValue: pendingItem.destinationFolder)
        _isCopy = State(initialValue: pendingItem.isCopy)
        _leaveSymlink = State(initialValue: pendingItem.leaveSymlink)
    }

    private var primaryURL: URL? {
        selectedURLs.first
    }

    private var parentFolderName: String {
        guard let first = primaryURL else { return "" }
        let parent = first.deletingLastPathComponent().lastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser.lastPathComponent
        return (parent == home || parent == "/") ? "" : parent
    }

    private var displayName: String {
        if selectedURLs.count > 1 {
            return "\(selectedURLs.count) Items Selected"
        }
        return primaryURL?.lastPathComponent ?? "Item"
    }

    private var hasAnyDirectory: Bool {
        for url in selectedURLs {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return true
            }
        }
        return false
    }

    private var directoryCount: Int {
        selectedURLs.filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }.count
    }

    private var iconName: String {
        if selectedURLs.count > 1 {
            return "square.stack.3d.up.fill"
        }
        return hasAnyDirectory ? "folder.fill" : "doc.fill"
    }

    private var formattedSize: String {
        if isCalculating {
            return "Calculating size…"
        }
        let sizeStr = ByteCountFormatter.string(fromByteCount: totalSizeBytes, countStyle: .file)
        if totalItemCount > 1 {
            return "\(sizeStr) • \(totalItemCount) files"
        }
        return sizeStr
    }

    private var existingVaultFolders: [String] {
        var set = Set<String>(vaultStats.folders.filter { $0 != "Google Drive" && !$0.hasPrefix(".") })
        let myDriveURL = RcloneDaemonSupervisor.shared.mountPoint.appendingPathComponent("My Drive")
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
        if !parentFolderName.isEmpty {
            set.insert(parentFolderName)
        }
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var destinationPreviewText: String {
        let cleanDest = destinationFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if selectedURLs.count == 1, let first = primaryURL {
            let target = cleanDest.isEmpty ? first.lastPathComponent : cleanDest
            return "Will be saved to: My Drive/\(target)"
        } else {
            if cleanDest.isEmpty {
                return "Each of the \(selectedURLs.count) items will be saved at: My Drive/<folder-name>"
            } else {
                return "Each of the \(selectedURLs.count) items will be saved inside: My Drive/\(cleanDest)/<folder-name>"
            }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "icloud.and.arrow.up.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Move to ZeroDrive Cloud")
                        .font(.headline)
                    Text("Review selected folders, choose their destination in My Drive, and optionally leave a shortcut")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // MARK: - 1. Source Card (With Full Selected Items List + Remove + Clear All + Add More)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("FROM THIS MAC (\(selectedURLs.count) SELECTED)")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button {
                                addMoreItemsViaPicker()
                            } label: {
                                Label("Add More…", systemImage: "plus.circle")
                                    .font(.caption2.bold())
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.mini)

                            Button(role: .destructive) {
                                selectedURLs.removeAll()
                                onCancel()
                            } label: {
                                Label("Clear Selection", systemImage: "xmark.circle")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.mini)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                Image(systemName: iconName)
                                    .font(.system(size: 26))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 34, height: 34)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(displayName)
                                        .font(.title3.weight(.semibold))
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    HStack(spacing: 6) {
                                        Text(formattedSize)
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)

                                        if let url = primaryURL {
                                            Text("•")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                            Text(truncatedBreadcrumb(selectedURLs.count > 1 ? url.deletingLastPathComponent().path : url.path))
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                                .help(url.path)
                                        }
                                    }
                                }

                                Spacer()

                                if selectedURLs.count > 1 {
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            showAllSelectedItems.toggle()
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Text(showAllSelectedItems ? "Hide List" : "Show All (\(selectedURLs.count))")
                                                .font(.caption.bold())
                                            Image(systemName: showAllSelectedItems ? "chevron.up" : "chevron.down")
                                                .font(.caption2.bold())
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }

                            // Scrollable list of all selected folders/files so the user can inspect or remove any item
                            if showAllSelectedItems && !selectedURLs.isEmpty {
                                Divider()

                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 4) {
                                        ForEach(selectedURLs, id: \.path) { itemURL in
                                            HStack(spacing: 8) {
                                                Image(systemName: isURLDirectory(itemURL) ? "folder.fill" : "doc.fill")
                                                    .font(.caption)
                                                    .foregroundStyle(Color.accentColor)
                                                    .frame(width: 16)

                                                Text(itemURL.lastPathComponent)
                                                    .font(.caption.weight(.medium))
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)

                                                Spacer()

                                                Text(truncatedBreadcrumb(itemURL.deletingLastPathComponent().path))
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                                    .lineLimit(1)

                                                if selectedURLs.count > 1 {
                                                    Button {
                                                        removeURLFromSelection(itemURL)
                                                    } label: {
                                                        Image(systemName: "xmark.circle.fill")
                                                            .font(.caption)
                                                            .foregroundStyle(.secondary)
                                                    }
                                                    .buttonStyle(.plain)
                                                    .help("Remove \(itemURL.lastPathComponent) from selection")
                                                }
                                            }
                                            .padding(.vertical, 3)
                                            .padding(.horizontal, 6)
                                            .background(Color.primary.opacity(0.03))
                                            .clipShape(RoundedRectangle(cornerRadius: 5))
                                        }
                                    }
                                }
                                .frame(maxHeight: selectedURLs.count > 4 ? 130 : CGFloat(selectedURLs.count * 28))
                            }
                        }
                        .padding(12)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    // MARK: - 2. Destination Card (Existing Folder Picker + New Folder + Browse My Drive)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("TO MY DRIVE (CLOUD VAULT)")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button {
                                browseOrCreateFolderInMyDrive()
                            } label: {
                                Label("Browse / New Folder in Finder…", systemImage: "folder.badge.plus")
                                    .font(.caption2.bold())
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.mini)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            // Row A: Existing Folder Picker Menu + Editable Path
                            HStack(spacing: 8) {
                                Image(systemName: "externaldrive.fill")
                                    .foregroundStyle(Color.accentColor)
                                Text("My Drive")
                                    .font(.subheadline.bold())
                                Image(systemName: "chevron.right")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.tertiary)

                                TextField(selectedURLs.count > 1 ? "Parent folder in My Drive (or leave blank for Top Level)" : "Folder name in My Drive", text: $destinationFolder)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.subheadline)

                                Menu {
                                    Button("Top Level (My Drive)") {
                                        destinationFolder = ""
                                    }
                                    if !parentFolderName.isEmpty {
                                        Button("Same Parent Folder (\(parentFolderName))") {
                                            destinationFolder = parentFolderName
                                        }
                                    }
                                    Divider()
                                    Section("Existing Folders in My Drive") {
                                        ForEach(existingVaultFolders, id: \.self) { folder in
                                            Button {
                                                if selectedURLs.count == 1, let first = primaryURL, folder != first.lastPathComponent {
                                                    destinationFolder = "\(folder)/\(first.lastPathComponent)"
                                                } else {
                                                    destinationFolder = folder
                                                }
                                            } label: {
                                                Label(folder, systemImage: "folder")
                                            }
                                        }
                                    }
                                    Divider()
                                    Button {
                                        isCreatingNewFolder = true
                                        newFolderNameInput = ""
                                    } label: {
                                        Label("New Folder…", systemImage: "folder.badge.plus")
                                    }
                                } label: {
                                    Label("Choose Folder", systemImage: "folder")
                                        .font(.caption.bold())
                                }
                                .frame(width: 130)
                            }

                            // Inline "+ New Folder" creator when clicked
                            if isCreatingNewFolder {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder.badge.plus")
                                        .foregroundStyle(Color.accentColor)
                                    TextField("New folder name (e.g. _DEV or Archive/2026)", text: $newFolderNameInput)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.caption)
                                    Button("Create & Select") {
                                        let trimmed = newFolderNameInput.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                                        if !trimmed.isEmpty {
                                            createFolderInMyDrive(trimmed)
                                            if selectedURLs.count == 1, let first = primaryURL {
                                                destinationFolder = "\(trimmed)/\(first.lastPathComponent)"
                                            } else {
                                                destinationFolder = trimmed
                                            }
                                        }
                                        isCreatingNewFolder = false
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)

                                    Button("Cancel") {
                                        isCreatingNewFolder = false
                                    }
                                    .controlSize(.small)
                                }
                                .padding(8)
                                .background(Color.accentColor.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }

                            // Row B: 1-Click Quick-Pick Chips for Existing Vault Folders
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    Text("Folders:")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)

                                    folderChip(title: "Top Level (My Drive)", isSelected: destinationFolder.isEmpty) {
                                        destinationFolder = ""
                                    }

                                    if !parentFolderName.isEmpty {
                                        folderChip(title: parentFolderName, isSelected: destinationFolder == parentFolderName) {
                                            destinationFolder = parentFolderName
                                        }
                                    }

                                    ForEach(existingVaultFolders.filter { $0 != parentFolderName }, id: \.self) { folder in
                                        let expectedVal = (selectedURLs.count == 1 && primaryURL != nil && folder != primaryURL!.lastPathComponent)
                                            ? "\(folder)/\(primaryURL!.lastPathComponent)"
                                            : folder
                                        folderChip(
                                            title: folder,
                                            isSelected: destinationFolder == folder || destinationFolder == expectedVal
                                        ) {
                                            destinationFolder = expectedVal
                                        }
                                    }

                                    Button {
                                        isCreatingNewFolder = true
                                        newFolderNameInput = ""
                                    } label: {
                                        Label("New Folder", systemImage: "plus")
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Color.accentColor.opacity(0.14))
                                            .foregroundStyle(Color.accentColor)
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            // Live Destination Preview
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.caption2)
                                    .foregroundStyle(Color.accentColor)
                                Text(destinationPreviewText)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .padding(12)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    // MARK: - 3. Action Mode (Move vs Copy) + Symlink Toggle (Works for 1 OR Multiple Folders!)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("HOW TO TRANSFER")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)

                        Picker("Method", selection: $isCopy) {
                            Text("Move & Free Up Mac Space").tag(false)
                            Text("Copy Only (Keep on Mac)").tag(true)
                        }
                        .pickerStyle(.segmented)

                        if !isCopy && hasAnyDirectory {
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle(isOn: $leaveSymlink) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "link")
                                            .foregroundStyle(Color.accentColor)
                                        Text(directoryCount > 1
                                             ? "Leave shortcuts (symlinks) in the old spots for all \(directoryCount) folders"
                                             : "Leave a shortcut (symlink) in the old spot")
                                            .font(.subheadline.weight(.medium))
                                    }
                                }
                                Text("Leaves a 0 KB link behind at the original Mac path so your apps, terminal scripts, and automations still find \(directoryCount > 1 ? "these folders" : "this folder") without changing any paths.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 22)
                            }
                            .padding(10)
                            .background(Color.accentColor.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                            Text(isCopy
                                 ? "Copies files to your Cloud Vault and keeps the originals on this Mac."
                                 : "Every file is verified safe in your Cloud Vault before it is removed from your Mac.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer Actions
            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    var finalItem = pendingItem
                    finalItem.urls = selectedURLs
                    finalItem.destinationFolder = destinationFolder.trimmingCharacters(in: .whitespacesAndNewlines)
                    finalItem.isCopy = isCopy
                    finalItem.leaveSymlink = (!isCopy && hasAnyDirectory) ? leaveSymlink : false
                    onConfirm(finalItem)
                } label: {
                    let countSuffix = selectedURLs.count > 1 ? " (\(selectedURLs.count))" : ""
                    Text(isCopy
                         ? "Copy to Cloud\(countSuffix)"
                         : (leaveSymlink && hasAnyDirectory
                            ? "Move & Leave Shortcut\(countSuffix)"
                            : "Move & Free Space\(countSuffix)"))
                        .frame(minWidth: 175)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedURLs.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: selectedURLs.count > 1 ? 610 : (hasAnyDirectory && !isCopy ? 520 : 460))
        .onAppear {
            calculateSourceStats()
        }
    }

    private func folderChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isSelected ? "folder.fill" : "folder")
                    .font(.caption2)
                Text(title)
                    .font(.caption2.weight(isSelected ? .bold : .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.12))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func isURLDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func removeURLFromSelection(_ url: URL) {
        selectedURLs.removeAll { $0.path == url.path }
        if selectedURLs.isEmpty {
            onCancel()
        } else {
            calculateSourceStats()
        }
    }

    private func addMoreItemsViaPicker() {
        let panel = NSOpenPanel()
        panel.title = "Add More Folders or Files to Move"
        panel.prompt = "Add to Selection"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if let first = primaryURL {
            panel.directoryURL = first.deletingLastPathComponent()
        }
        if panel.runModal() == .OK {
            for u in panel.urls {
                if !selectedURLs.contains(where: { $0.path == u.path }) {
                    selectedURLs.append(u)
                }
            }
            calculateSourceStats()
        }
    }

    private func browseOrCreateFolderInMyDrive() {
        let myDriveURL = RcloneDaemonSupervisor.shared.mountPoint.appendingPathComponent("My Drive")
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
            if selectedURLs.count == 1, let first = primaryURL, !rel.isEmpty, rel != first.lastPathComponent {
                destinationFolder = "\(rel)/\(first.lastPathComponent)"
            } else {
                destinationFolder = rel
            }
        }
    }

    private func createFolderInMyDrive(_ relativePath: String) {
        let myDriveURL = RcloneDaemonSupervisor.shared.mountPoint.appendingPathComponent("My Drive")
        let targetURL = myDriveURL.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
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

    private func calculateSourceStats() {
        isCalculating = true
        let urlsToScan = selectedURLs
        let skipDirs: Set<String> = ["node_modules", ".next", "__pycache__", ".venv", "venv", ".git", "Pods", "build", ".build"]

        DispatchQueue.global(qos: .userInitiated).async {
            var bytes: Int64 = 0
            var files: Int = 0

            for url in urlsToScan {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        if let enumerator = FileManager.default.enumerator(
                            at: url,
                            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isDirectoryKey],
                            options: [.skipsHiddenFiles]
                        ) {
                            while let fileURL = enumerator.nextObject() as? URL {
                                let name = fileURL.lastPathComponent
                                if skipDirs.contains(name) {
                                    enumerator.skipDescendants()
                                    continue
                                }
                                if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                                   values.isRegularFile == true {
                                    files += 1
                                    bytes += Int64(values.fileSize ?? 0)
                                }
                            }
                        }
                    } else {
                        files += 1
                        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
                            bytes += (attrs[.size] as? Int64) ?? 0
                        }
                    }
                }
            }

            let finalBytes = bytes
            let finalFiles = files
            DispatchQueue.main.async {
                self.totalSizeBytes = finalBytes
                self.totalItemCount = finalFiles
                self.isCalculating = false
            }
        }
    }
}
