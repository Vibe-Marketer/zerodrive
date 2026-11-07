import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct PendingTransferItem: Identifiable {
    public let id = UUID()
    public var urls: [URL]
    public var destinationFolder: String
    public var isCopy: Bool = false
    public var leaveSymlink: Bool = false
    /// Exact set of source folder paths that should leave a symlink behind (per-folder control)
    public var symlinkPaths: Set<String>

    public init(
        urls: [URL],
        destinationFolder: String = "",
        isCopy: Bool = false,
        leaveSymlink: Bool = false,
        symlinkPaths: Set<String>? = nil
    ) {
        self.urls = urls
        if !destinationFolder.isEmpty {
            self.destinationFolder = destinationFolder
        } else if urls.count > 1, let first = urls.first {
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
        if let explicit = symlinkPaths {
            self.symlinkPaths = explicit
        } else if leaveSymlink {
            var paths = Set<String>()
            for u in urls {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                    paths.insert(u.path)
                }
            }
            self.symlinkPaths = paths
        } else {
            self.symlinkPaths = []
        }
    }
}

public struct TransferConfirmationSheet: View {
    let pendingItem: PendingTransferItem
    let onConfirm: (PendingTransferItem) -> Void
    let onCancel: () -> Void

    @ObservedObject private var vaultStats = VaultStats.shared

    @State private var selectedURLs: [URL] = []
    @State private var symlinkPaths: Set<String> = []
    @State private var destinationFolder: String = ""
    @State private var isCopy: Bool = false
    @State private var isCalculating: Bool = true
    @State private var totalSizeBytes: Int64 = 0
    @State private var totalItemCount: Int = 0
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
        _symlinkPaths = State(initialValue: pendingItem.symlinkPaths)
        _destinationFolder = State(initialValue: pendingItem.destinationFolder)
        _isCopy = State(initialValue: pendingItem.isCopy)
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

    private var directoryURLs: [URL] {
        selectedURLs.filter { isURLDirectory($0) }
    }

    private var hasAnyDirectory: Bool {
        !directoryURLs.isEmpty
    }

    private var allDirectoriesSymlinked: Bool {
        let dirs = directoryURLs
        guard !dirs.isEmpty else { return false }
        return dirs.allSatisfy { symlinkPaths.contains($0.path) }
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
        if !parentFolderName.isEmpty {
            set.insert(parentFolderName)
        }
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var destinationPreviewText: String {
        let cleanDest = destinationFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if selectedURLs.count == 1, let first = primaryURL {
            let target = cleanDest.isEmpty ? first.lastPathComponent : cleanDest
            return "Destination: My Drive/\(target)"
        } else {
            if cleanDest.isEmpty {
                return "Each of the \(selectedURLs.count) items will be placed at: My Drive/<folder-name>"
            } else {
                return "Each of the \(selectedURLs.count) items will be placed inside: My Drive/\(cleanDest)/<folder-name>"
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
                    Text("Move Folders & Files to ZeroDrive Cloud")
                        .font(.headline)
                    Text("Check your selected items, toggle shortcuts (symlinks) per folder, and pick where they go in My Drive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // =========================================================================
                    // 1. SELECTED FOLDERS & FILES LIST (WITH PER-FOLDER SYMLINK TOGGLE!)
                    // =========================================================================
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center) {
                            Text("1. SELECTED FOLDERS & FILES (\(selectedURLs.count) SELECTED • \(formattedSize.uppercased()))")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button {
                                addMoreItemsViaPicker()
                            } label: {
                                Label("Add Folders / Files…", systemImage: "plus.circle.fill")
                                    .font(.caption.bold())
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button(role: .destructive) {
                                selectedURLs.removeAll()
                                symlinkPaths.removeAll()
                                onCancel()
                            } label: {
                                Label("Clear All", systemImage: "trash")
                                    .font(.caption.bold())
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        VStack(alignment: .leading, spacing: 0) {
                            // Column Header Bar inside the list box (with Master "Shortcut All" toggle)
                            HStack(spacing: 8) {
                                Text("FOLDER / FILE NAME")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.secondary)

                                Spacer()

                                if !isCopy && hasAnyDirectory {
                                    HStack(spacing: 6) {
                                        Text("LEAVE SHORTCUT (SYMLINK) PER FOLDER:")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(Color.accentColor)

                                        Button(allDirectoriesSymlinked ? "Uncheck All" : "Check All (\(directoryURLs.count))") {
                                            toggleAllDirectorySymlinks()
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                        .font(.caption2.bold())
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.1))

                            Divider()

                            // Scrollable List of Every Selected Folder/File with Per-Folder Symlink Toggle
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(selectedURLs.enumerated()), id: \.element.path) { idx, itemURL in
                                        let isDir = isURLDirectory(itemURL)
                                        let isSymlinked = symlinkPaths.contains(itemURL.path)

                                        HStack(spacing: 10) {
                                            Text("\(idx + 1).")
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                                .frame(width: 22, alignment: .trailing)

                                            Image(systemName: isDir ? "folder.fill" : "doc.fill")
                                                .font(.subheadline)
                                                .foregroundStyle(isDir ? Color.accentColor : Color.secondary)
                                                .frame(width: 18)

                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(itemURL.lastPathComponent)
                                                    .font(.subheadline.weight(.semibold))
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                Text(truncatedBreadcrumb(itemURL.path))
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }

                                            Spacer()

                                            // PER-FOLDER SYMLINK TOGGLE
                                            if !isCopy && isDir {
                                                Toggle(isOn: Binding(
                                                    get: { symlinkPaths.contains(itemURL.path) },
                                                    set: { enabled in
                                                        if enabled {
                                                            symlinkPaths.insert(itemURL.path)
                                                        } else {
                                                            symlinkPaths.remove(itemURL.path)
                                                        }
                                                    }
                                                )) {
                                                    HStack(spacing: 4) {
                                                        Image(systemName: "link")
                                                            .font(.caption2)
                                                        Text(isSymlinked ? "Shortcut ON" : "Leave Shortcut")
                                                            .font(.caption.weight(isSymlinked ? .bold : .regular))
                                                    }
                                                    .foregroundStyle(isSymlinked ? Color.accentColor : Color.secondary)
                                                }
                                                .toggleStyle(.checkbox)
                                                .help("Leave a 0 KB symlink at \(itemURL.path) pointing to My Drive so apps/scripts still find this folder")
                                            } else if !isDir {
                                                Text("File")
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }

                                            Button {
                                                removeURLFromSelection(itemURL)
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.subheadline)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                            .padding(.leading, 6)
                                            .help("Remove \(itemURL.lastPathComponent) from selection")
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(idx % 2 == 0 ? Color.clear : Color.primary.opacity(0.025))

                                        if idx < selectedURLs.count - 1 {
                                            Divider()
                                                .opacity(0.4)
                                        }
                                    }
                                }
                            }
                            .frame(minHeight: 140, maxHeight: 220)
                        }
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                        )
                    }

                    // =========================================================================
                    // 2. DESTINATION FOLDER IN MY DRIVE (CLOUD VAULT)
                    // =========================================================================
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("2. CHOOSE DESTINATION FOLDER IN MY DRIVE")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button {
                                browseOrCreateFolderInMyDrive()
                            } label: {
                                Label("Browse / Create Folder in Finder…", systemImage: "folder.badge.plus")
                                    .font(.caption.bold())
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        VStack(alignment: .leading, spacing: 10) {
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
                                    Label("Select Existing Folder", systemImage: "folder")
                                        .font(.caption.bold())
                                }
                                .frame(width: 170)

                                Button {
                                    isCreatingNewFolder = true
                                    newFolderNameInput = ""
                                } label: {
                                    Label("New Folder", systemImage: "plus")
                                        .font(.caption.bold())
                                }
                                .buttonStyle(.bordered)
                            }

                            if isCreatingNewFolder {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder.badge.plus")
                                        .foregroundStyle(Color.accentColor)
                                    TextField("Type new folder name in My Drive (e.g. _DEV or Archive/2026)", text: $newFolderNameInput)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.caption)
                                    Button("Create & Use") {
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

                            // 1-Click Existing Folder Pills
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    Text("Quick select:")
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
                                }
                            }

                            HStack(spacing: 6) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.caption2)
                                    .foregroundStyle(Color.accentColor)
                                Text(destinationPreviewText)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .padding(12)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    // =========================================================================
                    // 3. TRANSFER MODE (MOVE vs COPY)
                    // =========================================================================
                    VStack(alignment: .leading, spacing: 8) {
                        Text("3. TRANSFER METHOD")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)

                        Picker("Method", selection: $isCopy) {
                            Text("Move & Free Up Mac Space").tag(false)
                            Text("Copy Only (Keep on Mac)").tag(true)
                        }
                        .pickerStyle(.segmented)

                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                            if !isCopy && !symlinkPaths.isEmpty {
                                Text("\(symlinkPaths.count) of \(directoryURLs.count) folder(s) will leave a 0 KB shortcut (symlink) in their original Mac spot.")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                Text(isCopy
                                     ? "Copies files to your Cloud Vault and keeps the originals on this Mac."
                                     : "Every file is verified safe in your Cloud Vault before it is removed from your Mac.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
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
                    finalItem.symlinkPaths = isCopy ? [] : symlinkPaths
                    finalItem.leaveSymlink = !finalItem.symlinkPaths.isEmpty
                    onConfirm(finalItem)
                } label: {
                    let countSuffix = selectedURLs.count > 1 ? " (\(selectedURLs.count) Items)" : ""
                    let symlinkCount = symlinkPaths.count
                    Text(isCopy
                         ? "Copy to Cloud\(countSuffix)"
                         : (symlinkCount > 0
                            ? "Move\(countSuffix) & Leave \(symlinkCount) Shortcut\(symlinkCount == 1 ? "" : "s")"
                            : "Move & Free Space\(countSuffix)"))
                        .frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedURLs.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 640, height: 620)
        .onAppear {
            calculateSourceStats()
        }
    }

    private func toggleAllDirectorySymlinks() {
        let dirs = directoryURLs
        if allDirectoriesSymlinked {
            for d in dirs {
                symlinkPaths.remove(d.path)
            }
        } else {
            for d in dirs {
                symlinkPaths.insert(d.path)
            }
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
        symlinkPaths.remove(url.path)
        if selectedURLs.isEmpty {
            onCancel()
        } else {
            calculateSourceStats()
        }
    }

    private func addMoreItemsViaPicker() {
        let panel = NSOpenPanel()
        panel.title = "Add Folders or Files to Selection"
        panel.prompt = "Add to List"
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
        vaultStats.addFolderLocally(relativePath)
        let myDriveURL = RcloneDaemonSupervisor.shared.mountPoint.appendingPathComponent("My Drive")
        let targetURL = myDriveURL.appendingPathComponent(relativePath)
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
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
